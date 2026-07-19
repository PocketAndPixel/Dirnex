import Foundation
import Testing

@testable import DirnexCore

/// Tests for the background operation queue (PLAN.md §M2 "OperationQueue actor"): the
/// volume-aware scheduler over `CopyEngine`. The scheduling tests use a *gated* backend
/// whose clone blocks until the test releases it, so "which jobs are running together" is
/// deterministic rather than a race; the cancellation test uses a backend whose copy spins
/// on the cancel hook.
@Suite("FileOperationQueue")
struct FileOperationQueueTests {
    // MARK: - Single job

    @Test("runs a single copy job to completion")
    func runsSingleJob() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "hello")
        try tree.makeDir("dest")

        let queue = FileOperationQueue(backend: LocalBackend())
        let op = FileOperation(
            kind: .copy,
            sources: [try LocalBackend().stat(at: tree.vfsPath("a.txt"))],
            destinationDirectory: tree.vfsPath("dest")
        )
        let id = await queue.enqueue(op)
        await queue.waitUntilIdle()

        let snapshot = await queue.snapshot()
        #expect(snapshot.isIdle)
        let job = try #require(snapshot.jobs.first { $0.id == id })
        #expect(job.status == .finished)
        #expect(job.report?.succeeded == true)
        #expect(try String(contentsOfFile: tree.path("dest/a.txt"), encoding: .utf8) == "hello")
        // The aggregate settles at fully complete.
        #expect(snapshot.aggregate.finishedJobs == 1)
        #expect(snapshot.aggregate.fraction == 1)
    }

    @Test("clearFinished drops terminal jobs so a later batch's aggregate starts fresh")
    func clearFinishedResetsAggregate() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "hello")
        try tree.makeDir("dest")

        let queue = FileOperationQueue(backend: LocalBackend())
        await queue.enqueue(copy(tree, "a.txt", to: "dest"))
        await queue.waitUntilIdle()

        // The finished job is still in the snapshot (and its bytes in the aggregate)…
        var snapshot = await queue.snapshot()
        #expect(snapshot.jobs.count == 1)
        #expect(snapshot.aggregate.totalBytes > 0)

        await queue.clearFinished()

        // …until cleared: the queue is now empty, so a new batch measures itself.
        snapshot = await queue.snapshot()
        #expect(snapshot.jobs.isEmpty)
        #expect(snapshot.aggregate.totalBytes == 0)
        #expect(snapshot.aggregate.totalJobs == 0)
    }

    @Test("clearFinished keeps a still-running job")
    func clearFinishedKeepsRunning() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "a")
        try tree.makeDir("dest")

        let gate = Gate()
        let backend = GatedBackend(gate: gate, volumeFor: { _ in "V" })
        let queue = FileOperationQueue(backend: backend)

        let running = await queue.enqueue(copy(tree, "a.txt", to: "dest"))
        #expect(gate.waitForStarted(1) == 1)

        await queue.clearFinished() // nothing terminal yet → the running job survives
        var snapshot = await queue.snapshot()
        #expect(snapshot.jobs.first { $0.id == running }?.status == .running)

        gate.releaseAll()
        await queue.waitUntilIdle()
        await queue.clearFinished()
        snapshot = await queue.snapshot()
        #expect(snapshot.jobs.isEmpty)
    }

    // MARK: - Scheduling

    @Test("jobs sharing a volume run one at a time, in order")
    func serialPerVolume() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "a")
        try tree.writeFile("b.txt", contents: "b")
        try tree.makeDir("dest")

        let gate = Gate()
        // Everything on one volume → the two jobs must serialize.
        let backend = GatedBackend(gate: gate, volumeFor: { _ in "V" })
        let queue = FileOperationQueue(backend: backend)

        await queue.enqueue(copy(tree, "a.txt", to: "dest"))
        await queue.enqueue(copy(tree, "b.txt", to: "dest"))

        // Only the first job reaches the (blocking) clone; the second waits its turn.
        #expect(gate.waitForStarted(1) == 1)
        #expect(gate.waitForStarted(2, timeout: 0.3) == 1) // second held back
        var running = await queue.snapshot().aggregate.activeJobs
        #expect(running == 1)

        gate.release("a.txt") // let the first finish; the second should now start
        #expect(gate.waitForStarted(2) == 2)
        running = await queue.snapshot().aggregate.activeJobs
        #expect(running == 1) // still only one at a time

        gate.releaseAll()
        await queue.waitUntilIdle()
        let snapshot = await queue.snapshot()
        #expect(snapshot.jobs.allSatisfy { $0.status == .finished })
        #expect(try String(contentsOfFile: tree.path("dest/a.txt"), encoding: .utf8) == "a")
        #expect(try String(contentsOfFile: tree.path("dest/b.txt"), encoding: .utf8) == "b")
    }

    @Test("jobs on independent volumes run concurrently")
    func concurrentAcrossVolumes() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("pp")
        try tree.makeDir("pp/dest")
        try tree.makeDir("qq")
        try tree.makeDir("qq/dest")
        try tree.writeFile("pp/a.txt", contents: "a")
        try tree.writeFile("qq/b.txt", contents: "b")

        let gate = Gate()
        // Path-prefix → volume: the two jobs touch disjoint volumes, so they may overlap.
        let backend = GatedBackend(gate: gate, volumeFor: { path in
            if path.path.contains("/pp") { return "P" }
            if path.path.contains("/qq") { return "Q" }
            return "other"
        })
        let queue = FileOperationQueue(backend: backend)

        await queue.enqueue(copy(tree, "pp/a.txt", to: "pp/dest"))
        await queue.enqueue(copy(tree, "qq/b.txt", to: "qq/dest"))

        // Both jobs reach the blocking clone at once — concurrency across volumes.
        #expect(gate.waitForStarted(2) == 2)
        let running = await queue.snapshot().aggregate.activeJobs
        #expect(running == 2)

        gate.releaseAll()
        await queue.waitUntilIdle()
        #expect(try String(contentsOfFile: tree.path("pp/dest/a.txt"), encoding: .utf8) == "a")
        #expect(try String(contentsOfFile: tree.path("qq/dest/b.txt"), encoding: .utf8) == "b")
    }

    // MARK: - Pause / resume

    @Test("pause holds back queued work and parks the running job; resume drains it")
    func pauseHaltsDispatch() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("pp")
        try tree.makeDir("pp/dest")
        try tree.makeDir("qq")
        try tree.makeDir("qq/dest")
        try tree.writeFile("pp/a.txt", contents: "a")
        try tree.writeFile("qq/b.txt", contents: "b")

        let gate = Gate()
        let backend = GatedBackend(gate: gate, volumeFor: { path in
            path.path.contains("/pp") ? "P" : "Q"
        })
        let queue = FileOperationQueue(backend: backend)

        let first = await queue.enqueue(copy(tree, "pp/a.txt", to: "pp/dest"))
        #expect(gate.waitForStarted(1) == 1)

        await queue.pause()
        // The running job is now marked paused…
        let paused = await queue.snapshot()
        #expect(paused.isPaused)
        #expect(paused.jobs.first { $0.id == first }?.status == .paused)

        // …and a newly-enqueued job on an *independent* volume still won't start.
        await queue.enqueue(copy(tree, "qq/b.txt", to: "qq/dest"))
        #expect(gate.waitForStarted(2, timeout: 0.3) == 1)

        await queue.resume()
        #expect(gate.waitForStarted(2) == 2) // now the second one launches

        gate.releaseAll()
        await queue.waitUntilIdle()
        let snapshot = await queue.snapshot()
        #expect(!snapshot.isPaused)
        #expect(snapshot.jobs.allSatisfy { $0.status == .finished })
    }

    // MARK: - Cancellation

    @Test("cancelling a waiting job drops it before it ever starts")
    func cancelWaitingJob() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "a")
        try tree.writeFile("b.txt", contents: "b")
        try tree.makeDir("dest")

        let gate = Gate()
        let backend = GatedBackend(gate: gate, volumeFor: { _ in "V" }) // one volume → serial
        let queue = FileOperationQueue(backend: backend)

        await queue.enqueue(copy(tree, "a.txt", to: "dest"))
        let second = await queue.enqueue(copy(tree, "b.txt", to: "dest"))
        #expect(gate.waitForStarted(1) == 1) // first running, second waiting behind it

        await queue.cancel(second)
        let afterCancel = await queue.snapshot()
        #expect(afterCancel.jobs.first { $0.id == second }?.status == .cancelled)

        gate.releaseAll()
        await queue.waitUntilIdle()
        // The cancelled job never entered the (gated) clone.
        #expect(gate.startedCount == 1)
        let final = await queue.snapshot()
        #expect(final.jobs.first { $0.id == second }?.status == .cancelled)
        #expect(final.jobs.first { $0.id == second }?.report == nil) // never ran
        #expect(!FileManager.default.fileExists(atPath: tree.path("dest/b.txt")))
    }

    @Test("cancelling a running job unwinds the transfer and reports it cancelled")
    func cancelRunningJob() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("big.bin", bytes: 4096)
        try tree.makeDir("dest")

        let latch = Latch()
        let backend = BlockingCopyBackend(latch: latch)
        let queue = FileOperationQueue(backend: backend)

        let id = await queue.enqueue(copy(tree, "big.bin", to: "dest"))
        #expect(latch.wait(forCount: 1)) // the copy is in flight, spinning on the cancel hook

        await queue.cancel(id)
        await queue.waitUntilIdle()

        let snapshot = await queue.snapshot()
        let job = try #require(snapshot.jobs.first { $0.id == id })
        #expect(job.status == .cancelled)
        #expect(job.report?.wasCancelled == true)
    }

    // MARK: - Observation

    @Test("observe() streams the current state then every change")
    func observeStreamsSnapshots() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "hello")
        try tree.makeDir("dest")

        let queue = FileOperationQueue(backend: LocalBackend())
        var stream = await queue.observe().makeAsyncIterator()

        // The first element is the (empty) current snapshot, delivered immediately.
        let initial = await stream.next()
        #expect(initial?.jobs.isEmpty == true)

        await queue.enqueue(copy(tree, "a.txt", to: "dest"))

        // Pull snapshots until one shows the job finished.
        var sawFinished = false
        for _ in 0..<200 {
            guard let snapshot = await stream.next() else { break }
            if snapshot.jobs.contains(where: { $0.status == .finished }) {
                sawFinished = true
                break
            }
        }
        #expect(sawFinished)
    }

    // MARK: - Helpers

    /// A copy of one file (statted fresh) into a destination directory, both relative to
    /// `tree`.
    private func copy(_ tree: TempTree, _ source: String, to dest: String) -> FileOperation {
        FileOperation(
            kind: .copy,
            sources: [(try? LocalBackend().stat(at: tree.vfsPath(source)))].compactMap { $0 },
            destinationDirectory: tree.vfsPath(dest)
        )
    }
}

// MARK: - Test doubles

/// A rendezvous the test controls: a job's clone blocks in `enter` until the test releases
/// its key, so the scheduler's "who runs when" is observable and deterministic.
private final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started: [String] = []
    private var released: Set<String> = []
    private var releasedEverything = false

    /// Record that `key` reached the gate, then block until it (or everything) is released.
    func enter(_ key: String) {
        condition.lock()
        started.append(key)
        condition.broadcast()
        while !releasedEverything, !released.contains(key) { condition.wait() }
        condition.unlock()
    }

    func release(_ key: String) {
        condition.lock()
        released.insert(key)
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        releasedEverything = true
        condition.broadcast()
        condition.unlock()
    }

    var startedCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return started.count
    }

    /// Block until at least `count` distinct entries have arrived (or the timeout), then
    /// report how many did — so a test can assert both "reached N" and "stayed below N".
    @discardableResult
    func waitForStarted(_ count: Int, timeout: TimeInterval = 2) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while started.count < count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            condition.wait(until: Date().addingTimeInterval(min(remaining, 0.02)))
        }
        return started.count
    }
}

/// A one-way counter the test waits on — used to learn a spinning copy has actually begun.
private final class Latch: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0

    func signal() {
        condition.lock()
        count += 1
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func wait(forCount target: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while count < target {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return count >= target }
            condition.wait(until: Date().addingTimeInterval(min(remaining, 0.02)))
        }
        return true
    }
}

/// `LocalBackend` whose clone blocks on a `Gate` and whose volume ids come from an injected
/// closure — the scheduler's inputs (which volume, when a transfer completes) made
/// controllable so concurrency is deterministic. Real bytes still move on the real disk.
private struct GatedBackend: VFSBackend {
    let gate: Gate
    let volumeFor: @Sendable (VFSPath) -> String?
    private let inner = LocalBackend()

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try inner.moveItem(at: source, to: destination)
    }

    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool {
        gate.enter(source.lastComponent) // block until the test lets this transfer proceed
        return try inner.cloneItem(at: source, to: destination)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }

    func volumeIdentifier(for path: VFSPath) -> String? { volumeFor(path) }
}

/// `LocalBackend` that forces the chunked copy path and then *spins* on the cancel hook
/// instead of moving bytes — a transfer that runs until it's cancelled, so the queue's
/// running-job cancellation is exercised without a race on file size.
private struct BlockingCopyBackend: VFSBackend {
    let latch: Latch
    private let inner = LocalBackend()

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try inner.moveItem(at: source, to: destination)
    }

    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool {
        false // force the chunked copy path so `copyFile` (below) drives the transfer
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        latch.signal() // announce the copy is in flight
        while !isCancelled() { Thread.sleep(forTimeInterval: 0.005) }
        throw CancellationError() // the queue cancelled us — unwind like the real copyFile
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }
}
