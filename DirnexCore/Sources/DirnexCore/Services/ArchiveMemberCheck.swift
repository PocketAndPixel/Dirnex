import Foundation

/// The bytes an edited copy of an archive member started from, and which archive they came out of
/// (PLAN.md §M37 Slice 4).
///
/// The archive's half of M34's base. A server file's base is the server's bytes at the revision
/// its copy is checked against; a member's is the member's bytes as extracted, and the archive's
/// ``ArchiveIdentity`` as it was just before the extraction. While the archive still has that
/// identity nothing can have written the member, and once it has another, reading the member again
/// and comparing it with the base says whether anything did.
public struct ArchiveMemberBase: Sendable, Equatable {
    /// The member's bytes when the edit began, kept by ``EditBaseStore``.
    public let base: URL
    /// The archive those bytes were read out of. Stamped before the extraction, so a write during
    /// it reads as a move and costs a comparison rather than going unseen.
    public let archive: ArchiveIdentity

    public init(base: URL, archive: ArchiveIdentity) {
        self.base = base
        self.archive = archive
    }
}

/// What reading an edited member again from its archive found.
public enum ArchiveMemberVerdict: Sendable, Equatable {
    /// The archive is still the one the member was extracted from, so nothing was read.
    case unmoved
    /// No base is kept for the copy, so nothing says what the member was.
    case noBase
    /// The archive changed, and the member in it still holds the base's bytes: saving the copy
    /// back loses nobody's edit. Another member's write-back is the usual cause.
    case same
    /// The member in the archive differs from the base: something wrote it since. `byteSize` is the
    /// member's size as it is now, which says whether the merge window can read it.
    case different(byteSize: Int64)
    /// The archive changed and the member could not be read from it: the archive is gone or damaged,
    /// it is encrypted and no passphrase is in hand, or it no longer holds the member.
    case unreadable

    /// Whether the save's question has something to say about this member.
    public var isConcern: Bool {
        switch self {
        case .different, .unreadable: true
        case .unmoved, .noBase, .same: false
        }
    }
}

/// Settles whether an edited member changed inside its archive since the edit began (PLAN.md §M37
/// Slice 4).
///
/// Until this, saving a member back rewrote the archive with the copy whatever had happened to the
/// archive meanwhile, so a change another app made to the same member was replaced without a word.
/// The check reads the member again only when the archive moved, which costs nothing in the common
/// case: the archive's identity is one `stat`. When it moved, the members asked about are extracted
/// **in one call**, since a rewrite is a pass over the container and a check per member would make
/// a batch of forty saves forty passes over a compressed tar. No size bound: the rewrite that
/// follows extracts every member of the archive, so reading one again is never the larger cost.
///
/// The extraction is injected, since `bsdtar` and the encrypted reader live in the app; the
/// comparison is ``ByteComparator``'s, as the server's content check's is.
public struct ArchiveMemberCheck: Sendable {
    /// What one extraction placed: the directory it made, which the check removes, and where each
    /// requested member landed, in the order asked. A file that is not there is a member that did
    /// not land.
    public struct Placed: Sendable {
        public let directory: URL
        public let files: [URL]

        public init(directory: URL, files: [URL]) {
            self.directory = directory
            self.files = files
        }
    }

    /// One edited member: its path inside the archive, and the base kept for its copy.
    public struct Member: Sendable, Equatable {
        public let innerPath: String
        public let base: ArchiveMemberBase?

        public init(innerPath: String, base: ArchiveMemberBase?) {
            self.innerPath = innerPath
            self.base = base
        }
    }

    /// Extracts the members at these inner paths into a directory of its own, throwing when it
    /// cannot read the archive at all.
    public typealias Extract = @Sendable (_ innerPaths: [String]) throws -> Placed

    /// The archive on this disk.
    public let archivePath: String
    public let extract: Extract

    public init(archivePath: String, extract: @escaping Extract) {
        self.archivePath = archivePath
        self.extract = extract
    }

    /// What each member's archive holds against its base, in the order given. Blocking; call it off
    /// the main thread.
    public func verdicts(for members: [Member]) -> [ArchiveMemberVerdict] {
        let now = ArchiveIdentity.current(ofFileAt: archivePath)
        var verdicts: [ArchiveMemberVerdict] = members.map { member in
            guard let base = member.base else { return .noBase }
            return now != nil && now == base.archive ? .unmoved : .unreadable
        }
        let moved = members.indices.filter { verdicts[$0] == .unreadable }
        guard !moved.isEmpty, let placed = try? extract(moved.map { members[$0].innerPath }) else {
            return verdicts
        }
        defer { try? FileManager.default.removeItem(at: placed.directory) }
        for (index, file) in zip(moved, placed.files) {
            guard let base = members[index].base else { continue }
            verdicts[index] = Self.compare(file, with: base.base)
        }
        return verdicts
    }

    /// Read one member again and keep it in `store`, with the archive's identity stamped before the
    /// extraction: what a merge reads as the archive's version, and the copy's base once the merge
    /// is saved. Blocking; call it off the main thread.
    ///
    /// Throws what the extraction throws, and `VFSError.notFound` for a member that did not land or
    /// an archive that is not there. A store that cannot keep the file throws `fileWriteUnknown`.
    public func keep(_ innerPath: String, in store: EditBaseStore) throws -> ArchiveMemberBase {
        guard let stamp = ArchiveIdentity.current(ofFileAt: archivePath) else {
            throw VFSError.notFound(.local(archivePath))
        }
        let placed = try extract([innerPath])
        defer { try? FileManager.default.removeItem(at: placed.directory) }
        guard let file = placed.files.first, EditedFileRevision.current(ofFileAt: file.path) != nil
        else {
            let member = VFSPath(backend: .archive(forArchiveAt: archivePath), path: innerPath)
            throw VFSError.notFound(member)
        }
        guard let kept = store.keep(file) else { throw CocoaError(.fileWriteUnknown) }
        return ArchiveMemberBase(base: kept, archive: stamp)
    }

    /// The member as extracted at `file` against the base at `base`.
    private static func compare(_ file: URL, with base: URL) -> ArchiveMemberVerdict {
        guard let landed = EditedFileRevision.current(ofFileAt: file.path),
              let equal = try? ByteComparator.localFilesEqual(.local(file.path), .local(base.path))
        else { return .unreadable }
        return equal ? .same : .different(byteSize: landed.byteSize)
    }
}
