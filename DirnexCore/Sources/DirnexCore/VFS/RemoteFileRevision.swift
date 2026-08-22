import Foundation

/// What a **remote** file looked like when its bytes were fetched, so a save can ask "has anyone
/// else written this since?" before it overwrites them (PLAN.md §M21 Slice 10).
///
/// Editing a remote file is download → hand to an editor → upload the save, which every client in
/// this space does the same way. The hazard that shape carries is not the transfer: it is that
/// **the upload is a whole-file write with nothing standing behind it**. S3 has no locking at all
/// and a save is a whole-object `PUT`; SFTP and FTP have no lock either. So two people editing the
/// same file means the second save silently erases the first, with nothing on screen at any point
/// to say so. Recording what the file was at download and re-`stat`ing before the upload is what
/// turns that into a question the user gets to answer.
///
/// Deliberately **not** ``EditedFileRevision``, which is the same three words about the opposite
/// question. That one watches a *local temp copy* for the editor's own save and must therefore
/// ignore the inode, because a macOS editor's atomic save replaces the file it was handed; this one
/// watches a *remote object* for somebody else's write and has no inode to ignore. They will sit
/// beside each other in the same flow — the local watcher notices the save, this comparison decides
/// whether the save may land — which is exactly why they are two types and not one with a flag.
///
/// No `VFSBackend` change stands behind this: every field comes from a `stat` every remote backend
/// already answers.
public struct RemoteFileRevision: Sendable, Equatable {
    public let byteSize: Int64

    /// The server's modification time, or `nil` when the backend had none to give.
    ///
    /// `nil` is a real answer rather than a missing one: an S3 "folder" is a common prefix and not
    /// an object, so it has no `LastModified` whatsoever, and a stamp in a shape the parser does
    /// not recognize comes back the same way. `FileEntry` spells it ``FileEntry/unknownDate`` and
    /// this translates it, because a sentinel date compared as a date silently answers "unchanged"
    /// for two files that were never dated.
    public let modified: Date?

    /// The server's entity tag, when one was read.
    ///
    /// This is the field that makes the comparison **exact**, and it is the only one that can see
    /// the case the other two cannot: a file rewritten to the same length inside the same
    /// timestamp resolution. It changes ``isSuperseded(by:)``'s *rule* rather than merely its
    /// inputs — an entity tag that matches is proof of sameness, where a matching size and time is
    /// only an absence of evidence — which is why it could not have been collapsed into the
    /// disjunction after the fact.
    ///
    /// Supplied by S3 alone, out of the `<ETag>` of the very `ListObjectsV2` response the row was
    /// built from, so it costs no request of its own (``FileEntry/entityTag``). SFTP and FTP have
    /// no such thing and go on comparing size and time — and FTP's stamp is year-less, zone-less
    /// and on the server's clock on top of that (docs/NOTES.md ▸ curl), so over that one protocol
    /// an "unchanged" answer is the weakest this type can give.
    public let entityTag: String?

    public init(byteSize: Int64, modified: Date?, entityTag: String? = nil) {
        self.byteSize = byteSize
        self.modified = modified
        self.entityTag = entityTag
    }

    /// The revision a listing or a `stat` just reported for `entry`.
    public init(_ entry: FileEntry) {
        self.init(
            byteSize: entry.byteSize,
            modified: entry.hasModificationDate ? entry.modificationDate : nil,
            entityTag: entry.entityTag
        )
    }

    /// Whether `other` is a *different* state of the same file than this one — the question asked
    /// once more, immediately before an upload overwrites it.
    ///
    /// An entity tag on both sides settles it outright and nothing else is consulted: that is the
    /// whole point of having one, and falling back to size and time when the tags already
    /// disagreed would let a same-size rewrite through. Otherwise any difference in either field
    /// counts, which is the same asymmetry ``EditedFileRevision`` argues from the other direction —
    /// a spurious "someone changed this" is a dialog the user dismisses, while a missed one
    /// destroys their colleague's work with no dialog at all.
    ///
    /// Note what this cannot do: a difference found here is always real evidence of a write, but
    /// *no* difference is only as strong as the fields that could be compared — an entity tag is
    /// proof of sameness, a size and a date are an absence of evidence, and over FTP that date is
    /// year-less, zone-less and on the server's clock. So the two verdicts are not symmetric, and
    /// a caller must not read "not superseded" as "provably untouched".
    public func isSuperseded(by other: Self) -> Bool {
        if let mine = entityTag, let theirs = other.entityTag { return mine != theirs }
        return byteSize != other.byteSize || modified != other.modified
    }
}
