import Foundation

/// What an archive has to look like for an archive-rewrite undo to be allowed to proceed — its
/// size and modification time, recorded when the rewrite landed and checked again at ⌘Z.
///
/// Every other undo step refuses to destroy what it did not create: ``UndoStep/restore(from:to:)``
/// will not clobber a reoccupied destination, ``UndoStep/removeCreatedFolder(_:)`` will not remove a
/// folder the user has since filled. An archive swap has no such guard available from the paths
/// alone — the destination is *always* occupied, by the very file being replaced — so the guard has
/// to be a description of what is expected to be there. Without it a ⌘Z days later would silently
/// discard an archive something else had updated in the meantime.
///
/// **Not ``ArchiveIdentity``, and the difference is the inode.** That type identifies an archive so
/// a cache can tell it from a different archive of the same name, and the inode is what carries it
/// — which is right there and wrong here, because the swap *always* gives the archive a new inode.
/// A witness has to survive the operation it describes, so it is the two fields that do.
///
/// The modification time is a `Date` built the same way on both sides (a `stat`, seconds plus
/// nanoseconds), which is what makes an exact comparison sound across a relaunch: measured over
/// 200 000 random stamps, that `Date` survives the journal's JSON round trip byte-identically every
/// time, while sitting up to 179 ns from the true stamp — a constant error both sides share.
public struct ArchiveUndoWitness: Sendable, Equatable, Codable {
    public let byteSize: Int64
    public let modified: Date

    public init(byteSize: Int64, modified: Date) {
        self.byteSize = byteSize
        self.modified = modified
    }

    /// The witness of the file at `path` right now, or `nil` when there is no readable file there.
    ///
    /// Follows symlinks, matching ``ArchiveIdentity/current(ofFileAt:)``: what is being described is
    /// the bytes the archive reader reads.
    public static func current(ofFileAt path: String) -> Self? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return ArchiveUndoWitness(
            byteSize: Int64(status.st_size),
            modified: Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
                .addingTimeInterval(TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
        )
    }

    /// Whether the file at `path` is still the one this witness describes. A file that is not there
    /// answers `false` — absent is not "unchanged".
    public func matchesFile(at path: String) -> Bool {
        Self.current(ofFileAt: path) == self
    }
}
