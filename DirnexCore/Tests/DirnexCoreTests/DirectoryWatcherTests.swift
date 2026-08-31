import Foundation
import Testing

@testable import DirnexCore

/// Integration tests for the real FSEvents-backed watcher. These touch the filesystem
/// and wait on the kernel's event delivery, so they use a generous timeout and a short
/// coalescing latency to stay fast without being flaky.
@Suite("DirectoryWatcher")
struct DirectoryWatcherTests {
    /// A one-shot cross-thread signal: the FSEvents callback fires it from a background
    /// queue, the test awaits it on the test task. Rearmable for a second change.
    ///
    /// The timeout resumes the *same* continuation rather than racing a second task against it,
    /// which is what makes an event that never arrives a **failure** instead of a hang. The
    /// task-group version this replaces returned `false` on time and then waited for its other
    /// child to finish — a `withCheckedContinuation` nothing would ever resume, since a
    /// continuation carries no cancellation (docs/NOTES.md ▸ Swift 6 and concurrency). Every event
    /// these tests wait for does arrive, so it never showed; the first control run that withheld
    /// one wedged three tests past seven minutes with no assertion, which reads as broken
    /// infrastructure rather than as the regression it was reporting.
    private final class Pulse: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = 0
        private var fired = 0
        private var waiter: CheckedContinuation<Bool, Never>?
        /// Which wait is current, so an earlier wait's deadline cannot answer a later one.
        private var generation = 0

        /// Every fire since the watcher started, so a claim that something did **not** wake this
        /// stream is a count rather than a duration nobody can size (docs/NOTES.md ▸ Testing).
        func total() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }

        func fire() {
            lock.lock()
            fired += 1
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: true)
            } else {
                pending += 1
                lock.unlock()
            }
        }

        /// Forget everything counted so far, so a later claim is about what happened *after* this
        /// point rather than about what the setup left in flight.
        func reset() {
            lock.lock()
            fired = 0
            pending = 0
            lock.unlock()
        }

        /// Give up on whoever is waiting, so an event that never arrives fails its `#expect`.
        ///
        /// `token` is what makes a *finished* wait's deadline harmless. `Task.cancel()` does not
        /// unwind a `try? await Task.sleep` — the error is swallowed and the body runs on — so a
        /// deadline cancelled the instant its own wait succeeded would otherwise arrive here and
        /// resume the **next** wait with `false`. Measured as two pre-existing tests failing in
        /// 0.68 s rather than at the 10 s timeout, and only in a full run, which is the tell: a
        /// bounded wait that fails *fast* did not time out.
        private func giveUp(_ token: Int) {
            lock.lock()
            guard token == generation, let waiter else { return lock.unlock() }
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: false)
        }

        /// Await one pulse, or return `false` if `timeout` elapses first.
        /// Claim the next wait's token. Synchronous because Swift 6 refuses `NSLock.lock()`
        /// directly inside an `async` function (docs/NOTES.md ▸ Swift 6 and concurrency).
        private func nextGeneration() -> Int {
            lock.lock()
            defer { lock.unlock() }
            generation += 1
            return generation
        }

        func wait(timeout: Duration) async -> Bool {
            let token = nextGeneration()
            let deadline = Task {
                try? await Task.sleep(for: timeout)
                self.giveUp(token)
            }
            defer { deadline.cancel() }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if pending > 0 {
                    pending -= 1
                    lock.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    private let timeout: Duration = .seconds(10)

    /// Wait until every pulse has stopped counting — the setup's own events fully delivered — so a
    /// later count is about what the test did rather than about what it was still owed. A drain,
    /// not an assertion: nothing here claims an event will or will not arrive.
    private func quiesce(_ pulses: Pulse...) async {
        var previous = pulses.map { $0.total() }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
            let now = pulses.map { $0.total() }
            if now == previous { return }
            previous = now
        }
    }

    @Test("fires when a file is added to the watched directory")
    func firesOnAddition() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        let pulse = Pulse()
        let watcher = DirectoryWatcher(path: tree.vfsPath(), latency: 0.05) { pulse.fire() }
        defer { watcher.stop() }

        try tree.writeFile("new.txt", contents: "hi")
        #expect(await pulse.wait(timeout: timeout), "expected a change event for the new file")
    }

    @Test("keeps firing across successive changes")
    func firesOnSuccessiveChanges() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "a")

        let pulse = Pulse()
        let watcher = DirectoryWatcher(path: tree.vfsPath(), latency: 0.05) { pulse.fire() }
        defer { watcher.stop() }

        try tree.writeFile("b.txt", contents: "b")
        #expect(await pulse.wait(timeout: timeout), "expected an event for the addition")

        try FileManager.default.removeItem(atPath: tree.path("a.txt"))
        #expect(await pulse.wait(timeout: timeout), "expected an event for the removal")
    }

    @Test("one watcher over several directories fires for a change in any of them")
    func watchesSeveralDirectories() async throws {
        // What a merged listing needs: the Trash is several real directories shown as one place,
        // so a change in *any* of them has to wake the pane (PLAN.md §M8, §M9).
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("first")
        try tree.makeDir("second")

        let pulse = Pulse()
        let watcher = DirectoryWatcher(
            paths: [.local(tree.path("first")), .local(tree.path("second"))],
            latency: 0.05
        ) { pulse.fire() }
        defer { watcher.stop() }

        try tree.writeFile("first/a.txt", contents: "a")
        #expect(await pulse.wait(timeout: timeout), "expected an event from the first directory")

        try tree.writeFile("second/b.txt", contents: "b")
        #expect(await pulse.wait(timeout: timeout), "expected an event from the second directory")
    }

    // MARK: - Watching one file

    /// The case that decides `init(filePath:)`'s flag, and the one a pane browsing an archive most
    /// needs: a container rewritten **in place** keeps its inode, its name and its directory, so the
    /// only thing that changed is its bytes. Without `kFSEventStreamCreateFlagFileEvents` a stream
    /// on a file path reports the path appearing and disappearing and nothing else — measured at
    /// zero callbacks for exactly this write — which is the quiet direction: the pane goes on
    /// listing members the file no longer holds.
    @Test("a file watcher fires when the file is rewritten in place")
    func fileWatcherFiresOnInPlaceRewrite() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("pkg.zip", contents: "one")

        let pulse = Pulse()
        let watcher = DirectoryWatcher(filePath: tree.path("pkg.zip"), latency: 0.05) { pulse.fire() }
        defer { watcher.stop() }

        try tree.writeFile("pkg.zip", contents: "a longer archive")
        #expect(await pulse.wait(timeout: timeout), "expected an event for the rewritten file")
    }

    /// Delete-and-repack is the ordinary way to redo an archive, and it replaces the inode — so the
    /// stream has to be keyed to the *path* and go on reporting writes to whatever occupies it
    /// afterwards. A watcher that stopped here would fail exactly once and then look permanently
    /// healthy.
    @Test("a file watcher survives the file being deleted and recreated under the same name")
    func fileWatcherSurvivesRecreation() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("pkg.zip", contents: "one")

        let pulse = Pulse()
        let watcher = DirectoryWatcher(filePath: tree.path("pkg.zip"), latency: 0.05) { pulse.fire() }
        defer { watcher.stop() }

        try FileManager.default.removeItem(atPath: tree.path("pkg.zip"))
        try tree.writeFile("pkg.zip", contents: "two")
        #expect(await pulse.wait(timeout: timeout), "expected an event for the repack")

        // Drain before asking the question this test exists for. A repack arrives as *several*
        // callbacks, so a second wait taken straight after would be satisfied by the leftovers —
        // measured, it passed in 3 ms against a build that could not see an in-place write at all,
        // which is a control reading as inert.
        await quiesce(pulse)
        pulse.reset()

        try tree.writeFile("pkg.zip", contents: "three, longer still")
        #expect(await pulse.wait(timeout: timeout), "expected the stream to still be reporting")
    }

    /// The narrowness control, and the reason this watches the file rather than its enclosing
    /// directory: a pane sitting inside an archive in a busy folder must pay nothing for the churn
    /// around it. Without it, "watch the parent" would pass both tests above.
    ///
    /// The negative claim is settled by a **positive** signal rather than by a delay — a second
    /// watcher on the enclosing directory, which must fire for the sibling, so the count below is
    /// read only once FSEvents has actually delivered that change (docs/NOTES.md ▸ Testing).
    @Test("a file watcher stays silent for its siblings")
    func fileWatcherIgnoresSiblings() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("pkg.zip", contents: "one")

        let onFile = Pulse()
        let watcher = DirectoryWatcher(filePath: tree.path("pkg.zip"), latency: 0.05) { onFile.fire() }
        defer { watcher.stop() }
        let onDirectory = Pulse()
        let control = DirectoryWatcher(path: tree.vfsPath(), latency: 0.05) { onDirectory.fire() }
        defer { control.stop() }

        // Drain what arming left in flight before counting anything. FSEvents' "since now" is
        // approximate at the edges, so the write that *created* `pkg.zip` can still land on a
        // stream started after it — measured, as a count of 1 that reads exactly like a sibling
        // waking this watcher. Waiting for a change both streams must see is what makes the zero
        // below a fact about siblings rather than about timing.
        try tree.writeFile("pkg.zip", contents: "settling")
        #expect(await onFile.wait(timeout: timeout), "expected the file stream to be armed")
        #expect(await onDirectory.wait(timeout: timeout), "expected the control stream to be armed")
        // One pulse is not a drained stream: a single write can arrive as more than one callback,
        // so a reset taken on the first of them is overtaken by the rest and the stray reads
        // exactly like a sibling waking this watcher (measured, as an intermittent count of 1).
        // Quiesce until the count stops moving, *then* start counting.
        await quiesce(onFile, onDirectory)
        onFile.reset()
        onDirectory.reset()

        for round in 0..<3 {
            try tree.writeFile("other.txt", contents: "sibling \(round)")
            #expect(
                await onDirectory.wait(timeout: timeout),
                "the sibling's change reached FSEvents"
            )
            #expect(onFile.total() == 0, "a sibling is not this file changing")
        }

        // And the stream that stayed quiet is alive, not broken — the half that stops "never fire"
        // from passing.
        try tree.writeFile("pkg.zip", contents: "a longer archive")
        #expect(await onFile.wait(timeout: timeout), "expected an event for the file itself")
    }

    @Test("watching nothing is a watcher that never fires, not a failure")
    func watchingNoDirectories() {
        // A merge with no sources — no trash exists yet, iCloud Drive is off — has nothing to
        // notice, and must not be an error the caller has to handle.
        let watcher = DirectoryWatcher(paths: []) {}
        watcher.stop()
    }

    @Test("stop() is idempotent and safe to double-call")
    func stopIsIdempotent() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        let watcher = DirectoryWatcher(path: tree.vfsPath(), latency: 0.05) {}
        watcher.stop()
        watcher.stop()
    }
}
