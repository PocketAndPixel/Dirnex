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
    /// timestamp resolution. Nothing supplies one yet — `S3ListingParser` reads a listing's
    /// `<ETag>` element past without keeping it, and `FileEntry` has no field to carry it — so
    /// today it is always `nil` and the comparison falls back to size and time. It is here rather
    /// than deferred because it changes ``isSuperseded(by:)``'s *rule*, not just its inputs: an
    /// entity tag that matches is proof of sameness, where a matching size and time is only an
    /// absence of evidence, and the two cannot be collapsed into one comparison after the fact.
    public let entityTag: String?

    /// Whether ``modified`` is too coarse to be trusted as an "unchanged" answer.
    ///
    /// True over FTP, and the reason is the protocol rather than the implementation: `LIST` is not
    /// standardized, its stamp is **year-less** for recent files, carries **no zone**, and is on
    /// the *server's* clock (docs/NOTES.md ▸ curl). So an FTP mtime is approximate by construction
    /// — fine to display and sort by, and not something to compare two readings of the same file
    /// with. Carried on the value rather than re-derived from the path at each call site, so a
    /// caller wording a conflict dialog cannot forget to ask.
    public let timestampIsApproximate: Bool

    public init(
        byteSize: Int64,
        modified: Date?,
        entityTag: String? = nil,
        timestampIsApproximate: Bool = false
    ) {
        self.byteSize = byteSize
        self.modified = modified
        self.entityTag = entityTag
        self.timestampIsApproximate = timestampIsApproximate
    }

    /// The revision a listing or a `stat` just reported for `entry`.
    ///
    /// Reads the backend off the entry's own path, so the FTP caveat rides along without the caller
    /// naming a backend — the same reason ``FileEntry`` carries `isDataless` rather than making
    /// every sweep re-read `st_flags`.
    public init(_ entry: FileEntry) {
        self.init(
            byteSize: entry.byteSize,
            modified: entry.hasModificationDate ? entry.modificationDate : nil,
            entityTag: nil,
            timestampIsApproximate: entry.path.backend.hasApproximateTimestamps
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
    /// Note what this cannot do, and that ``timestampIsApproximate`` is where it is said: a
    /// difference found here is always real evidence of a write, but *no* difference is only as
    /// strong as the fields that were compared. See ``evidence(comparedWith:)``.
    public func isSuperseded(by other: Self) -> Bool {
        if let mine = entityTag, let theirs = other.entityTag { return mine != theirs }
        return byteSize != other.byteSize || modified != other.modified
    }

    /// What a "nothing has changed" answer from ``isSuperseded(by:)`` is actually worth, so the
    /// sentence the user reads can be honest about it.
    ///
    /// The four answers are not degrees of the same thing — each names a *different* blind spot,
    /// and the app words them differently rather than showing a confidence percentage nobody can
    /// act on.
    public func evidence(comparedWith other: Self) -> RemoteRevisionEvidence {
        if entityTag != nil, other.entityTag != nil { return .entityTag }
        guard modified != nil, other.modified != nil else { return .sizeOnly }
        if timestampIsApproximate || other.timestampIsApproximate {
            return .sizeAndApproximateTimestamp
        }
        return .sizeAndTimestamp
    }
}

/// How much weight two revisions comparing equal can carry (see
/// ``RemoteFileRevision/evidence(comparedWith:)``).
///
/// Ordered strongest first, and deliberately without a `<` — ranking these would invite a caller to
/// pick a floor, and the point is that each one is a different missing fact rather than less of the
/// same one.
public enum RemoteRevisionEvidence: Sendable, Equatable, CaseIterable {
    /// Both sides carried an entity tag and the tags matched. The file is byte-identical to what
    /// was downloaded; there is no case this misses.
    case entityTag
    /// Size and a trustworthy timestamp both matched. Misses only a rewrite that landed on the same
    /// length within the timestamp's own resolution.
    case sizeAndTimestamp
    /// Size and a timestamp matched, but the timestamp is the server-clock, zone-less, year-less
    /// kind FTP's `LIST` produces — so it misses any rewrite the coarse stamp cannot resolve, which
    /// is most of a working day's worth.
    case sizeAndApproximateTimestamp
    /// Only the sizes could be compared: at least one side reported no modification time at all.
    /// Misses every rewrite that kept the length.
    case sizeOnly
}
