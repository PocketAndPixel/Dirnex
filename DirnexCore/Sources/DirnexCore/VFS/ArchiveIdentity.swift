import Foundation

/// *Which* archive the file at a path currently is, so a cache keyed by that path can tell the
/// archive it snapshotted from a different archive that has since taken the same name
/// (PLAN.md §M4 "browse zip/tar as folders" — the mount, the preview extraction and the nested
/// mount are all keyed by the archive's on-disk path).
///
/// Everything an archive costs is paid once and remembered: the `bsdtar -tvf` that builds the
/// table of contents, the extraction a preview reads, the temp file a nested archive is mounted
/// from. That is right while the path keeps naming the same bytes, and delete-then-repack — the
/// ordinary way to redo an archive — makes it name different ones, at which point every one of
/// those caches is answering about a file that is gone. It fails quietly and in the worst
/// direction: the pane lists the *old* archive's members, and a preview hands over the old
/// archive's bytes, with nothing on screen to say the archive on disk disagrees.
///
/// The inode is what carries this — a repack writes a new file, so the number changes even when
/// the name, size and timestamp happen to line up. Size and modification time ride along for the
/// case an inode cannot see: an archive rewritten *in place*, keeping its inode.
///
/// Deliberately unlike ``EditedFileRevision``, which watches for a *save* and so must ignore the
/// inode, since a macOS editor's atomic save replaces the file it was given. Here the replacement
/// is exactly the event to catch.
public struct ArchiveIdentity: Sendable, Equatable {
    public let deviceID: Int32
    public let inode: UInt64
    public let byteSize: Int64
    public let modified: Date

    public init(deviceID: Int32, inode: UInt64, byteSize: Int64, modified: Date) {
        self.deviceID = deviceID
        self.inode = inode
        self.byteSize = byteSize
        self.modified = modified
    }

    /// The identity of the file at `path` right now, or `nil` when there is no readable file there.
    ///
    /// Follows symlinks, because what is being identified is the bytes the archive reader will
    /// read: a link whose target has been repointed at another archive is a different archive under
    /// the same path, which is precisely the case a stale mount must not survive.
    ///
    /// `nil` is **not** "unchanged" — a caller must treat it as a miss and re-read, which then
    /// fails with the real reason the file cannot be opened rather than serving a snapshot of one
    /// that is no longer there.
    public static func current(ofFileAt path: String) -> Self? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return ArchiveIdentity(
            deviceID: status.st_dev,
            inode: status.st_ino,
            byteSize: Int64(status.st_size),
            modified: Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
                .addingTimeInterval(TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
        )
    }

    /// Whether a cache stamped with `self` may still answer for the file at `path`.
    ///
    /// The unreadable case answers `false` on purpose (see ``current(ofFileAt:)``).
    public func stillDescribesFile(at path: String) -> Bool {
        guard let now = Self.current(ofFileAt: path) else { return false }
        return now == self
    }
}
