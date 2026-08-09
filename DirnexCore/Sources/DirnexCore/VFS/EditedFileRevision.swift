import Foundation

/// What a file looked like at a moment, so "has the user saved it since?" is a comparison rather
/// than a guess (PLAN.md §M4 edit-in-place write-back).
///
/// A member opened out of an archive lands in its own temp directory, and the app watches that
/// directory to notice a save. A directory watcher rather than a file one, deliberately: most macOS
/// editors save *atomically* — write a sibling, then rename over the original — so the file the
/// editor left behind is a different inode from the one that was opened, and anything holding a
/// descriptor or an inode number would watch a file nobody will ever write to again. The cost of
/// watching the directory is that it also fires for the editor's own scratch files, which is
/// exactly what this comparison filters out.
public struct EditedFileRevision: Sendable, Equatable {
    public let byteSize: Int64
    public let modified: Date

    public init(byteSize: Int64, modified: Date) {
        self.byteSize = byteSize
        self.modified = modified
    }

    /// The file's current revision, or `nil` when it is not there (or is not a regular file).
    ///
    /// `nil` is deliberately **not** "changed": an editor mid-atomic-save has already renamed the
    /// original away and not yet put the replacement in place, so a watcher firing in that window
    /// sees nothing. Treating that instant as an edit would offer to repack a file that does not
    /// exist; the next event, a few milliseconds later, carries the real one.
    public static func current(ofFileAt path: String) -> Self? {
        var status = stat()
        guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        return EditedFileRevision(
            byteSize: Int64(status.st_size),
            modified: Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
                .addingTimeInterval(TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
        )
    }

    /// Whether `other` is a later state of the same file — the question the watcher asks.
    ///
    /// A **different size counts whatever the timestamps say**, and the modification time is only
    /// consulted when the size matches, because the two failure directions are not equally
    /// expensive: missing a real edit loses the user's work silently, while a spurious offer to
    /// repack is a dialog they can decline. An editor that rewrites a file to the same size in the
    /// same whole second is the one case this cannot see, and sub-second `mtime` resolution — which
    /// APFS keeps and this reads in full — is what makes that case vanishingly rare rather than
    /// merely unlikely.
    public func isSuperseded(by other: Self) -> Bool {
        byteSize != other.byteSize || modified != other.modified
    }
}
