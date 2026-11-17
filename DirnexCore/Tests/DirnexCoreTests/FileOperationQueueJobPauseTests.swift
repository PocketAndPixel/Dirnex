import Foundation
import Testing

@testable import DirnexCore

/// Pausing one job apart from the rest of the queue (PLAN.md §M41): the progress dialog's Pause,
/// and what its Cancel does while it asks whether to stop.
///
/// Every transfer here runs through ``SteppingBackend``, whose copy counts a step between each of
/// the engine's checkpoints until the test lets it finish. A parked job is then a count that stops
/// moving and a running one a count that grows, which is the transfer's own behaviour rather than
/// the status the queue reports about it.
@Suite("FileOperationQueue per-job pause", .timeLimit(.minutes(1)))
struct FileOperationQueueJobPauseTests {
    @Test("pausing one job parks it and leaves a job on another volume running")
    func pausesOneJobOnly() async throws {
        let fixture = try Fixture(volumeFor: { $0.path.contains("/pp") ? "P" : "Q" })
        defer { fixture.cleanup() }
        let first = await fixture.enqueue("pp/a.bin")
        let second = await fixture.enqueue("qq/b.bin")
        #expect(await fixture.steps.waitUntilMoving("a.bin"))
        #expect(await fixture.steps.waitUntilMoving("b.bin"))

        await fixture.queue.pause(first)

        let paused = await fixture.queue.snapshot()
        #expect(!paused.isPaused, "the queue itself is not paused")
        #expect(paused.job(first)?.status == .paused)
        #expect(paused.job(first)?.isHeld == true)
        #expect(paused.job(second)?.status == .running)
        #expect(await fixture.steps.isParked("a.bin"))
        #expect(await fixture.steps.isMoving("b.bin"))

        await fixture.queue.resume(first)

        let resumed = await fixture.queue.snapshot()
        #expect(resumed.job(first)?.status == .running)
        #expect(resumed.job(first)?.isHeld == false)
        #expect(await fixture.steps.isMoving("a.bin"))
        try await fixture.finish()
        #expect(fixture.landed("pp/a.bin"))
        #expect(fixture.landed("qq/b.bin"))
    }

    /// Jobs on one pair of volumes run one at a time, so an F5 behind a background copy waits. Paused
    /// there, it must not start when the copy ahead of it finishes.
    @Test("a job paused before it starts is held back when its turn comes")
    func holdsAWaitingJob() async throws {
        let fixture = try Fixture(volumeFor: { _ in "V" })
        defer { fixture.cleanup() }
        let first = await fixture.enqueue("pp/a.bin")
        let second = await fixture.enqueue("qq/b.bin")
        #expect(await fixture.steps.waitUntilMoving("a.bin"))

        await fixture.queue.pause(second)
        #expect(await fixture.queue.snapshot().job(second)?.status == .paused)
        fixture.steps.release("a.bin")
        #expect(await fixture.waitFor(first, toBe: .finished))

        // Its turn has come and gone, and it has not moved.
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.steps.count("b.bin") == 0)
        let held = await fixture.queue.snapshot()
        #expect(held.job(second)?.status == .paused)
        #expect(held.job(second)?.isHeld == true)
        #expect(!held.isIdle, "a held job is still work to do")

        await fixture.queue.resume(second)
        #expect(await fixture.steps.waitUntilMoving("b.bin"))
        try await fixture.finish()
        #expect(fixture.landed("qq/b.bin"))
    }

    /// The queue bar's pause and the dialog's are separate: pausing and resuming the whole queue must
    /// not release a copy the user paused in its own dialog.
    @Test("the queue-wide resume leaves a job paused on its own")
    func queueResumeKeepsAHeldJob() async throws {
        let fixture = try Fixture(volumeFor: { $0.path.contains("/pp") ? "P" : "Q" })
        defer { fixture.cleanup() }
        let first = await fixture.enqueue("pp/a.bin")
        let second = await fixture.enqueue("qq/b.bin")
        #expect(await fixture.steps.waitUntilMoving("a.bin"))
        #expect(await fixture.steps.waitUntilMoving("b.bin"))

        await fixture.queue.pause(first)
        await fixture.queue.pause()
        #expect(await fixture.steps.isParked("b.bin"), "the queue-wide pause parks everything")
        await fixture.queue.resume()

        let snapshot = await fixture.queue.snapshot()
        #expect(snapshot.job(first)?.status == .paused)
        #expect(snapshot.job(second)?.status == .running)
        #expect(await fixture.steps.isParked("a.bin"))
        #expect(await fixture.steps.isMoving("b.bin"))

        await fixture.queue.resume(first)
        #expect(await fixture.steps.isMoving("a.bin"))
        try await fixture.finish()
    }

    @Test(
        "resuming one job while the whole queue is paused leaves it parked until the queue resumes"
    )
    func jobResumeWaitsForTheQueue() async throws {
        let fixture = try Fixture(volumeFor: { _ in "V" })
        defer { fixture.cleanup() }
        let job = await fixture.enqueue("pp/a.bin")
        #expect(await fixture.steps.waitUntilMoving("a.bin"))

        await fixture.queue.pause(job)
        await fixture.queue.pause()
        await fixture.queue.resume(job)

        let snapshot = await fixture.queue.snapshot()
        #expect(snapshot.job(job)?.isHeld == false)
        #expect(snapshot.job(job)?.status == .paused)
        #expect(await fixture.steps.isParked("a.bin"))

        await fixture.queue.resume()
        #expect(await fixture.queue.snapshot().job(job)?.status == .running)
        #expect(await fixture.steps.isMoving("a.bin"))
        try await fixture.finish()
    }

    /// Cancel on a job that never started: there is no engine to unwind, so the queue has to drop it
    /// itself, or it would sit `.paused` forever and the queue would never go idle.
    @Test("canceling a job paused before it started drops it without running it")
    func cancelsAHeldWaitingJob() async throws {
        let fixture = try Fixture(volumeFor: { _ in "V" })
        defer { fixture.cleanup() }
        _ = await fixture.enqueue("pp/a.bin")
        let second = await fixture.enqueue("qq/b.bin")
        #expect(await fixture.steps.waitUntilMoving("a.bin"))

        await fixture.queue.pause(second)
        await fixture.queue.cancel(second)

        let snapshot = await fixture.queue.snapshot()
        #expect(snapshot.job(second)?.status == .cancelled)
        #expect(snapshot.job(second)?.isHeld == false)
        try await fixture.finish()
        #expect(fixture.steps.count("b.bin") == 0)
        #expect(await fixture.queue.snapshot().job(second)?.report == nil, "it never ran")
        #expect(!fixture.landed("qq/b.bin"))
    }

    /// The dialog's Cancel pauses the job, asks, and on Stop cancels it while it is parked. The
    /// parked checkpoint has to wake and unwind, not wait for a resume that will never come.
    @Test("canceling a paused running job unwinds it")
    func cancelsAPausedRunningJob() async throws {
        let fixture = try Fixture(volumeFor: { _ in "V" })
        defer { fixture.cleanup() }
        let job = await fixture.enqueue("pp/a.bin")
        #expect(await fixture.steps.waitUntilMoving("a.bin"))
        await fixture.queue.pause(job)
        #expect(await fixture.steps.isParked("a.bin"))

        await fixture.queue.cancel(job)
        await fixture.queue.waitUntilIdle()

        let snapshot = await fixture.queue.snapshot()
        #expect(snapshot.job(job)?.status == .cancelled)
        #expect(snapshot.job(job)?.report?.wasCancelled == true)
        #expect(snapshot.job(job)?.isHeld == false)
        #expect(!fixture.landed("pp/a.bin"))
    }

    @Test("pausing a finished job, or one already paused, changes nothing")
    func pauseIsIdempotent() async throws {
        let fixture = try Fixture(volumeFor: { _ in "V" })
        defer { fixture.cleanup() }
        let job = await fixture.enqueue("pp/a.bin")
        #expect(await fixture.steps.waitUntilMoving("a.bin"))
        await fixture.queue.pause(job)
        await fixture.queue.pause(job)
        await fixture.queue.resume(job)
        #expect(await fixture.steps.isMoving("a.bin"), "one resume undoes two pauses")

        try await fixture.finish()
        await fixture.queue.pause(job)
        let snapshot = await fixture.queue.snapshot()
        #expect(snapshot.job(job)?.status == .finished)
        #expect(snapshot.job(job)?.isHeld == false)
        #expect(snapshot.isIdle)
    }
}

// MARK: - Fixture

/// Two one-file folders, `pp` and `qq`, each with a `dest` to copy into, and a queue over a
/// ``SteppingBackend`` whose volumes the test chooses.
private struct Fixture {
    let tree: TempTree
    let steps = Steps()
    let queue: FileOperationQueue

    init(volumeFor: @escaping @Sendable (VFSPath) -> String?) throws {
        tree = try TempTree()
        try tree.makeDir("pp/dest")
        try tree.makeDir("qq/dest")
        try tree.writeFile("pp/a.bin", bytes: 64)
        try tree.writeFile("qq/b.bin", bytes: 64)
        queue = FileOperationQueue(backend: SteppingBackend(steps: steps, volumeFor: volumeFor))
    }

    func cleanup() {
        steps.releaseAll() // never leave a copy thread spinning behind a failed test
        tree.cleanup()
    }

    /// Copy `relative`, a `folder/name` path, into that folder's `dest`.
    func enqueue(_ relative: String) async -> OperationJobID {
        let entry = try? LocalBackend().stat(at: tree.vfsPath(relative))
        return await queue.enqueue(FileOperation(
            kind: .copy,
            sources: [entry].compactMap { $0 },
            destinationDirectory: tree.vfsPath(Self.destination(of: relative))
        ))
    }

    /// `pp/a.bin` → `pp/dest`.
    private static func destination(of relative: String) -> String {
        "\((relative as NSString).deletingLastPathComponent)/dest"
    }

    /// Let every transfer finish, and wait for the queue to drain.
    func finish() async throws {
        steps.releaseAll()
        await queue.waitUntilIdle()
    }

    func waitFor(_ id: OperationJobID, toBe status: JobStatus) async -> Bool {
        for _ in 0..<400 {
            if await queue.snapshot().job(id)?.status == status { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Whether `relative`'s copy is in its `dest`.
    func landed(_ relative: String) -> Bool {
        let name = (relative as NSString).lastPathComponent
        return FileManager.default.fileExists(
            atPath: tree.path("\(Self.destination(of: relative))/\(name)")
        )
    }
}

private extension QueueSnapshot {
    func job(_ id: OperationJobID) -> JobSnapshot? {
        jobs.first { $0.id == id }
    }
}

// MARK: - Test doubles

/// How far each transfer has got, by file name, and which ones the test has let finish.
///
/// The waits poll with `Task.sleep` rather than blocking, for the reason `Gate.waitForStarted` in
/// `FileOperationQueueTests` gives: a blocked test body holds a cooperative thread the queue needs.
private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var released: Set<String> = []
    private var releasedEverything = false

    func step(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
    func release(_ key: String) { lock.withLock { _ = released.insert(key) } }
    func releaseAll() { lock.withLock { releasedEverything = true } }
    func isReleased(_ key: String) -> Bool { lock.withLock { releasedEverything || released.contains(
        key
    ) } }

    func waitUntilMoving(_ key: String) async -> Bool {
        for _ in 0..<400 where count(key) == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return count(key) > 0
    }

    /// No step over 150 ms, after 50 ms for a step already past its checkpoint to land.
    func isParked(_ key: String) async -> Bool {
        try? await Task.sleep(for: .milliseconds(50))
        let before = count(key)
        try? await Task.sleep(for: .milliseconds(150))
        return count(key) == before
    }

    func isMoving(_ key: String) async -> Bool {
        let before = count(key)
        for _ in 0..<400 where count(key) == before {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return count(key) > before
    }
}

/// `LocalBackend` with cloning refused, so a copy goes through `copyFile`, which steps between the
/// engine's checkpoints until the test releases the file. A paused job parks inside
/// `isCancelled`, so its count stops; a canceled one throws there, as the real copy does.
private struct SteppingBackend: VFSBackend {
    let steps: Steps
    let volumeFor: @Sendable (VFSPath) -> String?
    private let inner = LocalBackend()

    init(steps: Steps, volumeFor: @escaping @Sendable (VFSPath) -> String?) {
        self.steps = steps
        self.volumeFor = volumeFor
    }

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
    func cloneItem(at _: VFSPath, to _: VFSPath) throws -> Bool { false }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        let key = source.lastComponent
        while !steps.isReleased(key) {
            if isCancelled() { throw CancellationError() }
            steps.step(key)
            Thread.sleep(forTimeInterval: 0.002)
        }
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
