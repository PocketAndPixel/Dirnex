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

    /// What the cursor-following fetch is doing for the row a preview placeholder stands in for.
    enum AutomaticState: Equatable {
        /// Scheduled — still inside the settle delay — or transferring.
        case running
        /// The last automatic attempt for this row failed. Held until the cursor moves off it, and
        /// held for two reasons: the card has to say so rather than sitting on "hasn't been
        /// downloaded" while nothing is happening, and it is what stops the next delivery starting
        /// the same doomed transfer again.
        case failed
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

    /// The state of the automatic fetch standing behind `entry`, or `nil` when none is.
    func automaticState(for entry: FileEntry) -> AutomaticState? {
        guard let automatic, automatic.path == entry.path else { return nil }
        return automatic.state
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
        if let automatic, automatic.path == entry.path { return }
        cancelAutomaticFetch()
        let pending = AutomaticFetch(path: entry.path)
        automatic = pending
        let cancellation = pending.cancellation
        pending.task = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard let self, automatic === pending, !cancellation.isCancelled else { return }
            do {
                _ = try await fetch(
                    entry,
                    using: backend,
                    progress: { _ in },
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

    /// Abandon whatever automatic fetch is in flight, and forget a failed one.
    ///
    /// Called when the cursor leaves the row, and by the explicit gestures — a key somebody pressed
    /// supersedes a transfer nobody asked for, rather than racing it for the same object.
    func cancelAutomaticFetch() {
        guard let automatic else { return }
        automatic.cancellation.isCancelled = true
        automatic.task?.cancel()
        self.automatic = nil
    }

    /// One row's automatic attempt: which object, how it is going, and the flag the transfer's own
    /// thread reads to find out it has been abandoned.
    private final class AutomaticFetch {
        let path: VFSPath
        var state: AutomaticState = .running
        var task: Task<Void, Never>?
        /// Read from the transfer's thread, so it cannot be main-actor state — the same shape
        /// `RemoteFetchPrompt.Control` uses, minus the byte counter nothing draws here.
        let cancellation = CancellationFlag()

        init(path: VFSPath) {
            self.path = path
        }
    }
}

/// A one-bit `Sendable` box, so the main actor can tell a running transfer to stop.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
