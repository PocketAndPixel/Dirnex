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
    private final class Pulse: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = 0
        private var waiter: CheckedContinuation<Void, Never>?

        func fire() {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume()
            } else {
                pending += 1
                lock.unlock()
            }
        }

        /// Await one pulse, or return `false` if `timeout` elapses first.
        func wait(timeout: Duration) async -> Bool {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        self.lock.lock()
                        if self.pending > 0 {
                            self.pending -= 1
                            self.lock.unlock()
                            continuation.resume()
                        } else {
                            self.waiter = continuation
                            self.lock.unlock()
                        }
                    }
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        }
    }

    private let timeout: Duration = .seconds(10)

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
