import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The scan queue's own rules for a **bounded** set — the allowance a whole bar column shares, and
/// what may abandon a walk in flight (PLAN.md ▸ Still open, "Size bars are local-only …").
///
/// These need the real `DirectorySizeProvider` rather than a unit, because both rules are about
/// *when* it is asked: the pane re-derives its pending list and calls `requestScan` on every render,
/// so the queue's correctness is a property of being asked ten times a second while it works. The
/// backend is a fake serving a synthetic tree under a remote id, which is what makes the set bounded
/// at all — nothing here touches a network or a disk.
@MainActor
@Suite("Size scan queue", .serialized)
struct SizeScanQueueTests {
    fileprivate static let account = VFSBackendID.sftp(
        SFTPLocation(host: "queue.example", port: 22, username: "oleg")
    )

    /// A tree of `root/child/grandchild/file.bin`, whose **first** listing blocks until the test
    /// releases it.
    ///
    /// Two directories below the one being walked is the shape the test needs: `DirectorySizer`
    /// reads its cancellation flag once per directory it pops, so a walk blocked inside one listing
    /// observes an abandon only when it comes back for the next. A one-level tree would report a
    /// total either way and the test would pass against both builds.
    private final class BlockingBackend: VFSBackend, @unchecked Sendable {
        /// A copy rather than a reference to the suite's, because the backend is used off the main
        /// actor where the suite's own `@MainActor` static is unreachable.
        static let account = VFSBackendID.sftp(
            SFTPLocation(host: "queue.example", port: 22, username: "oleg")
        )

        /// A root unique to each test, because `DirectorySizeProvider` is a **singleton** whose
        /// cache outlives them: a second test reusing the first's paths finds the total already
        /// banked, never walks, and fails in its setup rather than on its claim.
        let root: String

        private let lock = NSLock()
        private var entered = false
        private var released = false

        init() { root = "/root-\(UUID().uuidString)" }

        var hasEnteredTheWalk: Bool {
            lock.lock()
            defer { lock.unlock() }
            return entered
        }

        func release() {
            lock.lock()
            released = true
            lock.unlock()
        }

        var id: VFSBackendID { Self.account }
        var capabilities: VFSCapabilities { [.read] }

        func listDirectory(at path: VFSPath) throws -> [FileEntry] {
            if path.path == "\(root)/child" {
                lock.lock()
                entered = true
                lock.unlock()
                // Waits to be *released* rather than counting out a duration, so nothing here rests
                // on a sleep being long enough (docs/NOTES.md ▸ Testing). The backstop exists only
                // so a broken test cannot hang the suite; no assertion may rest on reaching it.
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline {
                    lock.lock()
                    let done = released
                    lock.unlock()
                    if done { break }
                    usleep(5000)
                }
                return [directory("\(root)/child/grandchild")]
            }
            if path.path == "\(root)/child/grandchild" {
                return [file("\(root)/child/grandchild/file.bin", bytes: 4096)]
            }
            return []
        }

        func stat(at path: VFSPath) throws -> FileEntry { directory(path.path) }

        private func directory(_ path: String) -> FileEntry {
            entry(path, kind: .directory, bytes: 0)
        }

        private func file(_ path: String, bytes: Int64) -> FileEntry {
            entry(path, kind: .file, bytes: bytes)
        }

        private func entry(_ path: String, kind: FileEntry.Kind, bytes: Int64) -> FileEntry {
            FileEntry(
                path: VFSPath(backend: id, path: path),
                name: (path as NSString).lastPathComponent,
                kind: kind,
                byteSize: bytes,
                modificationDate: Date(),
                creationDate: Date(),
                isHidden: false,
                permissions: nil,
                inode: 0
            )
        }
    }

    private static func settle(
        within budget: Duration = .seconds(10),
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// The one that would have shipped a bug. `requestScan` calls into the queue's own "nothing left
    /// to hand out" path whenever every remaining child is cached or already in flight — and for a
    /// bounded set, which runs **one walk at a time**, that is precisely the state a re-render
    /// reaches while the *last* child is being walked. Routing it through `cancelScan`, which
    /// abandons the walk in flight, would therefore abandon the row the user is waiting for.
    ///
    /// It fails intermittently rather than always, which is why it is pinned here rather than looked
    /// for live: whether the abandon lands before the walk finishes is a race with the network.
    @Test("a re-render that queues nothing does not abandon the walk in flight")
    func reRenderDoesNotAbandonTheWalkInFlight() async throws {
        let backend = BlockingBackend()
        let root = VFSPath(backend: Self.account, path: backend.root)
        let child = VFSPath(backend: Self.account, path: "\(backend.root)/child")
        let provider = DirectorySizeProvider.shared

        provider.requestScan(for: root, children: [child], backend: backend, rule: .everything)
        let started = await Self.settle { backend.hasEnteredTheWalk }
        #expect(started, "the walk never started")

        // What the pane does on its next render: the same set, whose only child is now in flight, so
        // nothing is left to queue.
        provider.requestScan(for: root, children: [child], backend: backend, rule: .everything)
        backend.release()

        let landed = await Self.settle {
            provider.cachedSizes(for: [child], rule: .everything)[child] == 4096
        }
        #expect(landed, "the re-render abandoned the walk it was waiting on")
    }

    /// The other half, and the reason the two intents had to be split rather than merged: when the
    /// **pane** says it has stopped looking, a bounded walk really must be abandoned mid-walk —
    /// ``DirectorySizeBudget/abandonsWhenUnwatched``, which is the user's money and their bandwidth
    /// being spent on a number that now has no row to land in.
    @Test("a pane that stops looking abandons the walk in flight")
    func cancelScanAbandonsTheWalkInFlight() async throws {
        let backend = BlockingBackend()
        let root = VFSPath(backend: Self.account, path: backend.root)
        let child = VFSPath(backend: Self.account, path: "\(backend.root)/child")
        let provider = DirectorySizeProvider.shared

        provider.requestScan(for: root, children: [child], backend: backend, rule: .everything)
        let started = await Self.settle { backend.hasEnteredTheWalk }
        #expect(started, "the walk never started")

        provider.cancelScan(for: root)
        backend.release()

        // Nothing is banked, which is the observable an abandoned walk leaves: `cancellableSize`
        // answers `.unavailable`, and the cache stores neither a cancelled nor a failed total.
        let held = await Self.settle(within: .seconds(2)) {
            provider.cachedSizes(for: [child], rule: .everything)[child] != nil
        }
        #expect(!held, "an abandoned walk banked a total")
    }
}
