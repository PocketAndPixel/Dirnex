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
/// **A fetch nobody asked for is bounded three ways.** The cursor-following fetch is what makes
/// Quick View follow the cursor on a server at all, and what keeps it honest is that a *sweep* costs
/// nothing (the settle delay), a large object is declined rather than asked about
/// (`RemoteFetchPolicy`, tested in the core), and leaving the row abandons the transfer. Take a bound
/// away and this is a request per row the cursor passed over.
///
/// Neuter any one and the others' tests keep passing, which is the whole reason all three are
/// pinned: dropping the revision stamp makes "stale is dropped" fail while every request count stays
/// at zero, making the read path fetch makes the counts fail while freshness is untouched, and
/// dropping the settle delay makes only the sweep fail.

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

    // MARK: - The fetch nobody pressed a key for

    /// The bound that makes the whole thing affordable: travelling through a folder must cost
    /// nothing. Five rows scheduled back to back is what a held arrow key looks like from here —
    /// each supersedes the last inside the settle delay, so only where the cursor *stopped* is ever
    /// requested. Without the delay this is five transfers, which is the arrow-key spend the
    /// original no-passive-path rule was written against.
    ///
    /// The rows are stepped **with real gaps between them**, and that is the whole design of the
    /// test: scheduled back to back in one synchronous loop they would supersede each other before
    /// any of their tasks had run at all, so the assertion would pass with no settle delay
    /// whatsoever — a test that agrees with the bug. 50 ms apart is roughly a held arrow key, and
    /// the main actor suspends in between, which is what gives a delay-less scheduler its chance to
    /// spend five requests.
    @Test("sweeping the cursor across five rows transfers only the one it came to rest on")
    func aSweepTransfersOnlyTheRowItStopsOn() async {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]

        for name in names {
            cache.scheduleAutomaticFetch(Fixture.entry(name), using: backend, onSettled: {})
            try? await Task.sleep(for: .milliseconds(50))
        }
        // On the *cache*, not on `copyCount`: the counter is bumped as the transfer starts, so
        // waiting on it can return before the copy has been recorded — which fails as "the row it
        // stopped on was not fetched", i.e. as the feature being broken rather than as the wait.
        await settle { cache.cachedURL(for: Fixture.entry("e.txt")) != nil }

        #expect(backend.copyCount == 1)
        // And it is the *last* row, not the first: a scheduler that kept the earliest request would
        // put a file the cursor has left on screen under the current row's name.
        #expect(cache.cachedURL(for: Fixture.entry("e.txt")) != nil)
        #expect(cache.cachedURL(for: Fixture.entry("a.txt")) == nil)
    }

    /// The second bound, cheap half: leaving before the delay elapses means the request is never
    /// issued at all.
    @Test("leaving the row before the settle delay transfers nothing at all")
    func leavingTheRowTransfersNothing() async {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")

        cache.scheduleAutomaticFetch(entry, using: backend, onSettled: {})
        cache.cancelAutomaticFetch()
        await settle { false }

        #expect(backend.copyCount == 0)
        #expect(cache.automaticState(for: entry) == nil)
        #expect(cache.cachedURL(for: entry) == nil)
    }

    /// The second bound, and the half that actually bounds anything: a transfer **already on the
    /// wire** is abandoned when the cursor leaves. This is what makes a 16 MiB cap safe rather than
    /// merely small — the user pays for the seconds they spent looking at the row, not for the file.
    ///
    /// It needs a transfer slow enough to leave *during*, which is why the fake blocks. Every other
    /// test here finishes inside the same turn, so all of them are satisfied by the scheduler's
    /// identity guard and none of them can see whether cancellation reaches the transfer at all —
    /// measured, by neutering `cancelAutomaticFetch` and watching the whole suite stay green.
    @Test("leaving the row abandons a transfer that is already running")
    func leavingTheRowAbandonsARunningTransfer() async {
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")

        cache.scheduleAutomaticFetch(entry, using: backend, onSettled: {})
        await settle { backend.copyCount == 1 }
        #expect(backend.copyCount == 1)

        cache.cancelAutomaticFetch()
        await settle { backend.wasCancelledMidTransfer }

        #expect(backend.wasCancelledMidTransfer)
        #expect(cache.cachedURL(for: entry) == nil)
    }

    @Test("a landed automatic fetch reports itself and leaves the copy served")
    func landedFetchReportsAndCaches() async {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let settled = Landing()

        #expect(cache.automaticState(for: entry) == nil)
        cache.scheduleAutomaticFetch(entry, using: backend) { settled.times += 1 }
        // Immediately, not once the bytes arrive: the placeholder card drawn on this very delivery
        // has to say a download is on its way rather than that none is.
        #expect(cache.automaticState(for: entry) == .running)
        await settle { settled.times > 0 }

        #expect(settled.times == 1)
        #expect(cache.cachedURL(for: entry) != nil)
        // Cleared on success, so the next delivery reads "nothing pending" and finds the bytes.
        #expect(cache.automaticState(for: entry) == nil)
    }

    /// A failure is reported to the caller once and then *remembered*, and both halves matter. The
    /// report is what stops the card claiming a download is still coming; the memory is what stops
    /// the re-delivery that report causes from starting the same doomed transfer again — an
    /// unattended retry loop against a server, which is the expensive direction.
    @Test("a failed automatic fetch reports once and is not retried by the delivery it causes")
    func failedFetchReportsOnceAndDoesNotLoop() async {
        let backend = CountingBackend(outcome: .fail)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let settled = Landing()

        cache.scheduleAutomaticFetch(entry, using: backend) { settled.times += 1 }
        await settle { settled.times > 0 }
        #expect(cache.automaticState(for: entry) == .failed)

        // What every later preview delivery for this row does — including the one the report above
        // triggered.
        for _ in 0..<3 {
            cache.scheduleAutomaticFetch(entry, using: backend) { settled.times += 1 }
        }
        await settle { false }

        #expect(backend.copyCount == 1)
        #expect(settled.times == 1)
    }

    /// The state belongs to *a row*, not to the cache: a card is drawn per cursor position, and one
    /// that read a neighbour's pending fetch would say a download was on its way for a file nothing
    /// had been asked about.
    @Test("the pending state answers only for the row it belongs to")
    func pendingStateIsPerRow() async {
        let backend = CountingBackend()
        let cache = RemoteFileCache()

        cache.scheduleAutomaticFetch(Fixture.entry("a.txt"), using: backend, onSettled: {})

        #expect(cache.automaticState(for: Fixture.entry("a.txt")) == .running)
        #expect(cache.automaticState(for: Fixture.entry("b.txt")) == nil)
        cache.cancelAutomaticFetch()
        await settle { false }
    }

    /// Poll until `isDone`, or until comfortably past the settle delay — `await`, never a run-loop
    /// spin, since what is being waited for is a detached transfer's continuation and a spin never
    /// suspends the main actor (docs/NOTES.md ▸ Testing). The `false` predicate is the deliberate
    /// spelling of "wait out the delay and prove nothing happened".
    private func settle(until isDone: () -> Bool) async {
        for _ in 0..<40 {
            if isDone() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// A main-actor counter for the landing callback. A plain `var` captured by an `@escaping
/// @MainActor` closure cannot be mutated from it; a tiny reference type can.
@MainActor
private final class Landing {
    var times = 0
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
        /// Sit in the transfer until `isCancelled` says otherwise — a stand-in for the seconds a
        /// real object spends on the wire, which every other outcome here finishes too fast to have.
        case block
    }

    static let body = "downloaded!"

    let id = Fixture.backendID
    let capabilities: VFSCapabilities = [.read, .write]

    private let outcome: Outcome
    private let lock = NSLock()
    private var counts = (copy: 0, stat: 0, list: 0)
    private var destination: String?
    private var observedCancellation = false

    init(outcome: Outcome = .succeed) {
        self.outcome = outcome
    }

    var copyCount: Int { lock.withLock { counts.copy } }
    var statCount: Int { lock.withLock { counts.stat } }
    var listCount: Int { lock.withLock { counts.list } }
    var lastDestination: String? { lock.withLock { destination } }
    /// Whether a `.block` transfer was actually told to stop, as opposed to running to its own
    /// backstop. The assertion a cancellation test rests on: `throws CancellationError` is not
    /// evidence here for the same reason it was not in Slice 10's probe — the caller's own boundary
    /// check throws whether or not anything was interrupted.
    var wasCancelledMidTransfer: Bool { lock.withLock { observedCancellation } }

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
        case .block:
            // On `BlockingWork`'s global queue, not a cooperative worker, which is the whole reason
            // that type exists — so sleeping here spends a thread the pool will replace rather than
            // one the process shares (docs/NOTES.md ▸ Swift 6 and concurrency).
            for _ in 0..<500 where !isCancelled() {
                usleep(10_000)
            }
            guard isCancelled() else { return }
            lock.withLock { observedCancellation = true }
            throw CancellationError()
        }
    }
}
