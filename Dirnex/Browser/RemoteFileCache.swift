import DirnexCore
import Foundation

/// The copies of remote files this window has pulled down, so a preview, an open or an edit works
/// on a real file the way every other client in this space does it (PLAN.md §M21 Slice 10).
///
/// An editor and a Quick Look plugin both want a path, not a stream, so nobody streams: Cyberduck
/// and Transmit each download to a temp directory, hand that copy over, and upload the save. This is
/// that temp directory, scoped to the window beside `archivePreviewCache` and for the same reason —
/// an edit outlives whichever pane started it.
///
/// **Stamped with the revision, not merely keyed by the path.** A cache keyed by a path outlives the
/// object that path named, which is the `ArchiveIdentity` lesson arriving a second time: replace an
/// object and the entry left behind hands over the *previous* object's bytes under the new object's
/// name. The stamp is `RemoteFileRevision`, and the crucial difference from the archive case is
/// where it comes from — an archive's `stat` is a syscall, while a remote one is a **billed round
/// trip** measured at half a second (docs/NOTES.md ▸ curl for S3). So the freshness check reads the
/// revision off the `FileEntry` the pane is already displaying, which costs nothing and is the same
/// listing the user is looking at.
///
/// Copies land under one shared temp root, each in its own UUID directory keeping the file's **real
/// name** — the editor shows that name, and the edit watcher watches the directory (docs/NOTES.md ▸
/// AppKit). The root is purged at launch, exactly like `ArchiveExtractor`'s.
@MainActor
final class RemoteFileCache {
    /// One downloaded copy: where it landed, and what the object looked like when it was fetched.
    struct Entry {
        let url: URL
        /// What a save compares against before it overwrites — see `RemoteFileRevision`.
        let revision: RemoteFileRevision
    }

    private var fetched: [VFSPath: Entry] = [:]

    /// The shared temp root every remote fetch writes beneath.
    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DirnexRemote", isDirectory: true)
    }

    /// Remove every downloaded copy. Called once at launch, before anything can be fetching, so it
    /// can clear the whole root without racing a transfer in flight.
    static func purgeTemporaries() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    /// The downloaded copy of `entry`'s object if one is here **and still matches what the listing
    /// says** — otherwise `nil`, which the caller reads as "nothing to show yet".
    ///
    /// Synchronous and free: no request, no syscall beyond the one that checks the copy is still on
    /// disk. That is what lets the passive preview path call it on every cursor movement without
    /// spending anything, which is the whole reason the split between the passive and explicit paths
    /// can exist at all.
    func cachedURL(for entry: FileEntry) -> URL? {
        cached(for: entry)?.url
    }

    /// The same, with the revision the copy was taken at — what a save re-`stat`s against.
    func cached(for entry: FileEntry) -> Entry? {
        guard let held = fetched[entry.path] else { return nil }
        guard !held.revision.isSuperseded(by: RemoteFileRevision(entry)) else {
            drop(entry.path)
            return nil
        }
        // A temp directory the OS cleared out from under us is a miss, never "unchanged": handing
        // back a path with no file at it would render as a damaged document rather than as an error.
        guard FileManager.default.fileExists(atPath: held.url.path) else {
            drop(entry.path)
            return nil
        }
        return held
    }

    /// What the copy of `path` was last known to be, for a write-back's conflict check. Unlike
    /// ``cached(for:)`` this asks nothing about freshness — the caller is about to go and ask the
    /// server itself, which is the only answer worth having before an overwrite.
    func revision(for path: VFSPath) -> RemoteFileRevision? {
        fetched[path]?.revision
    }

    /// Forget the copy of `path`, without deleting it — the file may still be open in an editor, and
    /// the write-back watcher holds its own reference to it.
    func drop(_ path: VFSPath) {
        fetched[path] = nil
    }

    /// Record that the copy of `path` now stands for `revision` — what a successful upload leaves
    /// behind, since the editor still holds that same file and a second save must be compared
    /// against what *we* just wrote rather than against what was there before.
    func rebaseline(_ path: VFSPath, to revision: RemoteFileRevision, url: URL) {
        fetched[path] = Entry(url: url, revision: revision)
    }

    /// Download `entry`'s bytes into a fresh temp directory and remember where they landed.
    ///
    /// Reuses an existing copy when one is here and still matches, so a preview followed by ⏎
    /// followed by F4 costs one transfer rather than three. `progress` is called with the running
    /// byte total so a sheet can draw a determinate bar — the size is known from the listing, which
    /// is what makes it determinate where iCloud's could only ever be a spinner.
    ///
    /// **A cancelled or failed fetch leaves nothing behind.** Cancellation genuinely abandons the
    /// transfer now (PLAN.md §M21 Slice 10), which for the first time makes a *partial* file
    /// possible — and a truncated document renders as damage rather than as an error, so the partial
    /// is removed here rather than kept as something `-C -` could resume. That is right for a cache
    /// and wrong for F5, which is why the two do opposite things with the same bytes.
    func fetch(
        _ entry: FileEntry,
        using backend: any VFSBackend,
        progress: @escaping @Sendable (Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> URL {
        if let held = cached(for: entry) { return held.url }
        let directory = Self.temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(entry.name)
        let source = entry.path

        // `BlockingWork.run` is deliberately non-throwing (its body is a synchronous engine that
        // reports rather than throws), so the transfer's error rides back as a `Result`.
        let outcome = await BlockingWork.run { () -> Result<Void, any Error> in
            Result {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                var moved: Int64 = 0
                try backend.copyFile(
                    at: source,
                    to: .local(destination.path),
                    progress: { chunk in
                        moved += chunk
                        progress(moved)
                    },
                    isCancelled: isCancelled
                )
            }
        }
        do {
            try outcome.get()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        fetched[source] = Entry(url: destination, revision: RemoteFileRevision(entry))
        return destination
    }

    // MARK: - The fetch nobody pressed a key for

    /// What the fetch standing behind the row a preview placeholder draws is doing — whichever
    /// gesture started it.
    ///
    /// One vocabulary for both kinds, because the card that reads it draws one thing: a download of
    /// this file, its bar, and the button that calls it off. Which gesture asked for it decides
    /// where the bytes are *reported* (▸ the two sections below), never what the user is told.
    enum PreviewFetchState: Equatable {
        /// Scheduled — still inside the settle delay — or transferring.
        case running
        /// The last automatic attempt for this row failed. Held until the cursor moves off it, and
        /// held for two reasons: the card has to say so rather than sitting on "hasn't been
        /// downloaded" while nothing is happening, and it is what stops the next delivery starting
        /// the same doomed transfer again.
        ///
        /// Reachable from the automatic path only: an explicit gesture reports its failure in an
        /// alert naming the real error, and the card then goes back to offering its button.
        case failed
        /// The user pressed Stop on this row.
        ///
        /// A state of its own rather than simply forgetting the fetch, and the difference is the
        /// whole point: forgetting it would let the very next preview delivery start the download
        /// again, so a file under the limit could not be stopped at all — every cursor step would
        /// re-schedule what had just been called off. Held for the same span as `.failed`, and
        /// cleared the moment the cursor moves on, so coming back to the row offers it afresh.
        case stopped
    }

    /// How long the cursor has to rest on a row before its bytes are worth pulling.
    ///
    /// The delay is what makes a *sweep* free, which is the whole safety argument: an arrow key
    /// held down repeats every 30–90 ms, so travelling through a folder requests nothing, and one
    /// tap that comes to rest starts one transfer. Deliberately shorter than the ~0.5 s round trip
    /// that follows it (docs/NOTES.md ▸ curl for S3) — the settle must not be what the wait is made
    /// of.
    private static let settleDelay: Duration = .milliseconds(400)

    /// The one automatic fetch that can be in flight, because there is one preview and it follows
    /// one cursor. Single-flight is structural rather than a rule somebody keeps: scheduling a
    /// different row abandons whatever the last one was doing, which is also what bounds the cost of
    /// arrowing across a folder of large objects.
    private var automatic: AutomaticFetch?

    /// The state of the fetch standing behind `entry`, or `nil` when none is.
    ///
    /// The explicit record is asked first, and the order is what makes the card honest rather than
    /// arbitrary: an explicit gesture calls the automatic one off before it starts, so the only way
    /// both can name this row at once is a leftover the cursor has not cleared yet — and of the two,
    /// the one somebody pressed a key for is the transfer actually running.
    func previewFetchState(for entry: FileEntry) -> PreviewFetchState? {
        if let explicit, explicit.path == entry.path { return explicit.state }
        guard let automatic, automatic.path == entry.path else { return nil }
        return automatic.state
    }

    /// How many bytes the fetch of `entry` has moved so far, or `nil` when none is running for that
    /// row.
    ///
    /// A **pull**, deliberately: a fetch reports every chunk, and turning each into a re-delivery of
    /// the whole preview would repaint the surface hundreds of times for a number in one label. The
    /// card polls this instead, which is the shape `RemoteFetchPrompt`'s sheet already uses and for
    /// the same reason.
    func previewFetchProgress(for entry: FileEntry) -> Int64? {
        if let explicit, explicit.path == entry.path {
            return explicit.state == .running ? explicit.moved.value : nil
        }
        guard let automatic, automatic.path == entry.path, automatic.state == .running else {
            return nil
        }
        return automatic.moved.value
    }

    /// Pull `entry`'s bytes down because the cursor has come to rest on it, and call `onSettled`
    /// when the outcome is worth re-drawing — either the bytes landed, or the attempt failed and the
    /// card has to stop claiming one is on its way.
    ///
    /// **The caller has already decided this is allowed.** `RemoteFetchPolicy` weighs the size
    /// against `.cursorPreview`, which declines rather than confirming, so nothing here can raise a
    /// dialog on a keystroke. Failures are equally silent: an alert nobody asked for, dismissed with
    /// every arrow key, is worse than a card that says the download did not work and offers a
    /// button that *does* report.
    ///
    /// Re-scheduling the row already pending is a no-op, which is what lets every preview delivery
    /// call this without looping — including the delivery that this method's own `onSettled` causes.
    func scheduleAutomaticFetch(
        _ entry: FileEntry,
        using backend: any VFSBackend,
        onSettled: @escaping @MainActor () -> Void
    ) {
        // A row somebody has already pressed a key for is spoken for, whichever way that turned
        // out: running, it would be a second transfer of the same object beside the one on screen;
        // stopped, it would start again what the user has just called off — the same argument
        // ``PreviewFetchState/stopped`` makes for the automatic one, arriving from the other side.
        if let explicit, explicit.path == entry.path { return }
        if let automatic, automatic.path == entry.path { return }
        cancelAutomaticFetch()
        let pending = AutomaticFetch(path: entry.path)
        automatic = pending
        let cancellation = pending.cancellation
        let moved = pending.moved
        pending.task = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard let self, automatic === pending, !cancellation.isCancelled else { return }
            do {
                _ = try await fetch(
                    entry,
                    using: backend,
                    progress: { moved.value = $0 },
                    isCancelled: { cancellation.isCancelled }
                )
            } catch {
                // Our own cancellation is not a failure to report: the cursor moved on, and the row
                // this card belonged to is no longer on screen.
                guard automatic === pending, !cancellation.isCancelled else { return }
                pending.state = .failed
                onSettled()
                return
            }
            guard automatic === pending else { return }
            automatic = nil
            onSettled()
        }
    }

    /// Abandon whatever automatic fetch is in flight, and forget a failed or stopped one.
    ///
    /// Called when the cursor leaves the row, and by the explicit gestures — a key somebody pressed
    /// supersedes a transfer nobody asked for, rather than racing it for the same object.
    func cancelAutomaticFetch() {
        guard let automatic else { return }
        automatic.cancellation.isCancelled = true
        automatic.task?.cancel()
        self.automatic = nil
    }

    /// Call off whatever the placeholder card is drawing — its Stop button, which since the card
    /// draws an explicit transfer too has to reach either kind.
    ///
    /// The row is **remembered** as stopped rather than forgotten. See ``PreviewFetchState/stopped``
    /// for why that is load-bearing for the automatic fetch: without it a file under the limit
    /// cannot be stopped at all, because the delivery that Stop itself causes would start it again.
    /// It matters for an explicit one for a quieter reason — the card then says the download was
    /// stopped instead of going back to a sentence about the size, which is a fact about the file
    /// and not about what just happened.
    func stopPreviewFetch() {
        if let explicit, explicit.state == .running {
            explicit.cancellation.isCancelled = true
            explicit.state = .stopped
            return
        }
        guard let automatic else { return }
        automatic.cancellation.isCancelled = true
        automatic.task?.cancel()
        automatic.state = .stopped
    }

    // MARK: - The fetch somebody did press a key for

    /// The transfer an explicit gesture (⌃Q, ⌘Y, ⏎, F4, or the placeholder card's own Download
    /// button) is running, so the card can draw *that* download rather than only the one nobody
    /// asked for.
    ///
    /// The transfer itself belongs to `RemoteFetchPrompt`, which owns the question, the failure
    /// report and the copy — this is only the record of it, so that one preview surface reports one
    /// download whichever gesture started it. Before it existed the card sat on "files this large
    /// aren't downloaded automatically", still offering its button, while the bytes it was asking
    /// for were already on their way, and the only thing drawing them was a second progress dialog
    /// over the top of it.
    private var explicit: ExplicitFetch?

    /// Record the transfer `path` is about to run, handing the cache the two boxes the transfer's
    /// own thread will use: the counter it reports into and the flag it watches.
    ///
    /// The boxes are the *caller's*, not copies — the card reads and the Stop button writes the same
    /// values the transfer is looking at, which is what makes the bar live and Stop actually stop.
    func beginExplicitFetch(
        _ path: VFSPath,
        moved: ByteCounter,
        cancellation: CancellationFlag
    ) {
        explicit = ExplicitFetch(path: path, moved: moved, cancellation: cancellation)
    }

    /// Forget the record of `path`'s explicit transfer, now that it has finished, failed or
    /// unwound.
    ///
    /// **A stopped one is kept**, and that is the whole subtlety: a stopped transfer ends by
    /// throwing `CancellationError`, so the unwinding arrives here immediately afterwards and would
    /// erase the one fact the card is about to state. Nothing is stranded — the next explicit fetch
    /// of that row replaces it, and no other row can see it.
    func endExplicitFetch(_ path: VFSPath) {
        guard let explicit, explicit.path == path, explicit.state == .running else { return }
        self.explicit = nil
    }

    /// One row's explicit attempt. No `Task`: the transfer is the prompt's, and what is held here is
    /// the record of it — which is why cancellation travels through the flag rather than through a
    /// handle on the work.
    private final class ExplicitFetch {
        let path: VFSPath
        var state: PreviewFetchState = .running
        let moved: ByteCounter
        let cancellation: CancellationFlag

        init(path: VFSPath, moved: ByteCounter, cancellation: CancellationFlag) {
            self.path = path
            self.moved = moved
            self.cancellation = cancellation
        }
    }

    /// One row's automatic attempt: which object, how it is going, and the flag the transfer's own
    /// thread reads to find out it has been abandoned.
    private final class AutomaticFetch {
        let path: VFSPath
        var state: PreviewFetchState = .running
        var task: Task<Void, Never>?
        /// Both read from the transfer's thread, so neither can be main-actor state — the same shape
        /// `RemoteFetchPrompt` holds for an explicit transfer, split into two boxes because they
        /// travel separately: the flag goes *into* the transfer and the counter comes back out.
        let cancellation = CancellationFlag()
        let moved = ByteCounter()

        init(path: VFSPath) {
            self.path = path
        }
    }
}

/// A one-bit `Sendable` box, so the main actor can tell a running transfer to stop.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

/// A `Sendable` running total, so a transfer can report from its own thread and the main actor can
/// read it whenever it next draws.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    var value: Int64 {
        get { lock.withLock { total } }
        set { lock.withLock { total = newValue } }
    }
}
