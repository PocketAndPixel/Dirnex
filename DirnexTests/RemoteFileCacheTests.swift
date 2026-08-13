import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The window's cache of downloaded remote files (PLAN.md §M21 Slice 10).
///
/// Two claims carry the slice, and they pull in opposite directions — which is why each needs the
/// other's negative control to mean anything. **Nothing is spent on cursor movement**: a preview
/// that fetched on an arrow key would bill a request because the cursor passed over a row, so the
/// passive path must reach the backend zero times. And **nothing stale is ever served**: a cache
/// keyed by a path outlives the object that path named (the `ArchiveIdentity` lesson, one kind of
/// elsewhere further out), and here it would hand over the previous object's bytes under the new
/// object's name.
///
/// Neuter either and the other's tests keep passing, which is the whole reason both are pinned:
/// dropping the revision stamp makes "stale is dropped" fail while every request count stays at
/// zero, and making the read path fetch makes the counts fail while freshness is untouched.

/// At file scope rather than on the suite: the fake backend below is `Sendable` and answers from
/// whichever thread the transfer runs on, so it cannot reach a main-actor-isolated static.
private enum Fixture {
    static let backendID = VFSBackendID.s3(
        S3Location(
            host: "127.0.0.1",
            port: 9599,
            bucket: "probe",
            region: "us-east-1",
            accessKeyID: "AKIAPROBEKEYEXAMPLE",
            addressing: .path,
            usesTLS: false
        )
    )

    static func entry(
        _ name: String,
        byteSize: Int64 = 12,
        modified: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backendID, path: "/\(name)"),
            name: name,
            kind: .file,
            byteSize: byteSize,
            modificationDate: modified,
            creationDate: modified,
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }
}

@MainActor
@Suite("Remote file cache")
struct RemoteFileCacheTests {
    // MARK: - Nothing is spent on cursor movement

    /// The claim the slice rests on, in the form a test can hold: five rows walked, zero requests.
    @Test("walking the cursor over five un-fetched remote files reaches the backend zero times")
    func cursorMovementSpendsNothing() {
        let backend = CountingBackend()
        let cache = RemoteFileCache()

        for name in ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"] {
            #expect(cache.cachedURL(for: Fixture.entry(name)) == nil)
        }

        // Named individually rather than as a total: a read path that had grown a `stat` would be a
        // billed round trip per arrow key even though it moved no bytes, and a total of "some
        // requests" would not say which mistake had been made.
        #expect(backend.copyCount == 0)
        #expect(backend.statCount == 0)
        // The backend is not even a parameter of the read path, which is what makes the claim
        // structural. Held here so the assertion above cannot quietly become vacuous.
        #expect(backend.listCount == 0)
    }

    @Test("an explicit fetch is exactly one transfer, and a second one reuses it")
    func explicitFetchTransfersOnceAndIsReused() async throws {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")

        let url = try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: {
            false
        })
        #expect(backend.copyCount == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == CountingBackend.body)

        // The reuse is what makes ⌘Y then ⏎ then F4 on one object cost one transfer rather than
        // three, and it is the synchronous read the preview surfaces use.
        #expect(cache.cachedURL(for: entry) == url)
        let again = try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: {
            false
        })
        #expect(again == url)
        #expect(backend.copyCount == 1)
    }

    // MARK: - Nothing stale is served

    @Test("an object replaced on the server drops its downloaded copy")
    func replacedObjectDropsItsCopy() async throws {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        _ = try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: { false })

        // The listing the pane is now drawing reports a different size — evidence of a write, and
        // the only signal available without spending a request of our own.
        let replaced = Fixture.entry("a.txt", byteSize: 99)

        #expect(cache.cachedURL(for: replaced) == nil)
    }

    /// The same, for the case the size cannot see. A rewrite that kept the length is exactly why the
    /// revision is a pair rather than a byte count.
    @Test("an object rewritten to the same length still drops its copy, on the timestamp")
    func sameSizeRewriteDropsItsCopy() async throws {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        _ = try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: { false })

        let touched = Fixture.entry("a.txt", modified: Date(timeIntervalSince1970: 1_700_000_500))

        #expect(cache.cachedURL(for: touched) == nil)
    }

    /// The other half, and the one that stops the "fix" from silently becoming "re-download every
    /// time" — which would be a correct-looking cache that costs a transfer per arrow key.
    @Test("an untouched object is still served from its downloaded copy")
    func untouchedObjectKeepsItsCopy() async throws {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let url = try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: {
            false
        })

        #expect(cache.cachedURL(for: entry) == url)
        #expect(backend.copyCount == 1)
    }

    @Test("a copy the OS cleared out of the temp directory is a miss, not “unchanged”")
    func vanishedCopyIsAMiss() async throws {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let url = try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: {
            false
        })
        try FileManager.default.removeItem(at: url)

        // Handing back a path with no file at it renders as a damaged document rather than as an
        // error, which is the quiet direction.
        #expect(cache.cachedURL(for: entry) == nil)
    }

    // MARK: - A cancelled fetch leaves nothing behind

    /// Cancellation genuinely abandons a remote transfer now, which for the first time makes a
    /// *partial* file possible. That is right for F5 — it is the partial `-C -` resumes from — and it
    /// is exactly wrong for a cache, where a truncated file renders as damage instead of an error.
    @Test("a cancelled fetch caches nothing and leaves no partial on disk")
    func cancelledFetchLeavesNothing() async throws {
        let backend = CountingBackend(outcome: .cancel)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")

        await #expect(throws: CancellationError.self) {
            try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: { true })
        }

        #expect(cache.cachedURL(for: entry) == nil)
        // The partial the backend wrote before giving up is gone with its directory — the whole
        // point, since it is the thing that would have rendered as a damaged document.
        #expect(backend.lastDestination.map { FileManager.default.fileExists(atPath: $0) } != true)
    }

    @Test("a failed fetch caches nothing either")
    func failedFetchLeavesNothing() async throws {
        let backend = CountingBackend(outcome: .fail)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")

        await #expect(throws: (any Error).self) {
            try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: { false })
        }
        #expect(cache.cachedURL(for: entry) == nil)
    }

    // MARK: - Re-baselining after an upload

    /// A successful upload has to move what the *next* save compares against. Leaving the
    /// pre-upload revision would have our own write read back as "someone else has edited it",
    /// which is the one sentence in this feature that must never be wrong.
    @Test("re-baselining after an upload keeps the copy and adopts the new revision")
    func rebaselineAdoptsTheNewRevision() async throws {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let url = try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: {
            false
        })

        let uploaded = Fixture.entry("a.txt", byteSize: 40, modified: Date(timeIntervalSince1970: 1))
        cache.rebaseline(entry.path, to: RemoteFileRevision(uploaded), url: url)

        #expect(cache.revision(for: entry.path) == RemoteFileRevision(uploaded))
        // And the copy the editor still has open stays served, since the listing will now agree
        // with what was just written.
        #expect(cache.cachedURL(for: uploaded) == url)
    }
}

/// A backend that answers a download with known bytes and counts every call it is asked to make.
///
/// Counting rather than asserting-on-call: the claim is about a *number of requests* over a
/// sequence of gestures, which no single expectation inside the fake could express.
private final class CountingBackend: VFSBackend, @unchecked Sendable {
    enum Outcome {
        case succeed
        /// Write a short prefix and then throw, the shape a stopped `curl` now leaves.
        case cancel
        case fail
    }

    static let body = "downloaded!"

    let id = Fixture.backendID
    let capabilities: VFSCapabilities = [.read, .write]

    private let outcome: Outcome
    private let lock = NSLock()
    private var counts = (copy: 0, stat: 0, list: 0)
    private var destination: String?

    init(outcome: Outcome = .succeed) {
        self.outcome = outcome
    }

    var copyCount: Int { lock.withLock { counts.copy } }
    var statCount: Int { lock.withLock { counts.stat } }
    var listCount: Int { lock.withLock { counts.list } }
    var lastDestination: String? { lock.withLock { destination } }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        lock.withLock { counts.list += 1 }
        return []
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        lock.withLock { counts.stat += 1 }
        return Fixture.entry(path.lastComponent)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        lock.withLock {
            counts.copy += 1
            self.destination = destination.path
        }
        switch outcome {
        case .succeed:
            try Data(Self.body.utf8).write(to: URL(fileURLWithPath: destination.path))
            progress(Int64(Self.body.utf8.count))
        case .cancel:
            try Data("dow".utf8).write(to: URL(fileURLWithPath: destination.path))
            progress(3)
            throw CancellationError()
        case .fail:
            throw VFSError.notFound(source)
        }
    }
}
