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
}
