import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The window's cache of downloaded remote files (PLAN.md §M21 Slice 10).
///
/// Three claims carry it, and they pull against each other — which is why each needs the others'
/// negative controls to mean anything.
///
/// **The read path spends nothing.** `cachedURL(for:)` is called on every cursor movement and does
/// not take a backend at all, so a preview surface asking "are the bytes here" must reach the server
/// zero times, `stat` included.
///
/// **Nothing stale is ever served.** A cache keyed by a path outlives the object that path named
/// (the `ArchiveIdentity` lesson, one kind of elsewhere further out), and here it would hand over
/// the previous object's bytes under the new object's name.
///
/// Neuter either and the other's tests keep passing, which is the whole reason both are pinned:
/// dropping the revision stamp makes "stale is dropped" fail while every request count stays at
/// zero, and making the read path fetch makes the counts fail while freshness is untouched.
///
/// What the cache *does* when the cursor comes to rest — the bounded, unasked fetch — is
/// `RemotePreviewFetchTests`, and the fixtures both use are `RemoteFetchFixtures`.
@MainActor
@Suite("Remote file cache")
struct RemoteFileCacheTests {
    // MARK: - The read path spends nothing

    /// The claim the slice rests on, in the form a test can hold: five rows read, zero requests.
    @Test("asking whether five un-fetched remote files are here reaches the backend zero times")
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
