import Foundation

/// One directory entry, as produced by a `VFSBackend` `stat`/`list`.
///
/// This is a plain value snapshot — everything the panel needs to render a row
/// without touching disk again. Recursive directory sizes and Quick Look thumbnails
/// are computed lazily elsewhere; they are not part of the base stat.
///
/// Identity (`id`) is the entry's `VFSPath`. Within a directory that is unique and
/// stable, which is what the panel uses to keep the cursor on the "same" file across
/// a live refresh (PLAN.md §6).
public struct FileEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case file
        case directory
        case symlink
        /// Sockets, FIFOs, block/char devices — shown but not navigable.
        case other
    }

    public let path: VFSPath
    public let name: String
    public let kind: Kind
    /// Logical size in bytes. For directories this is the directory file's own
    /// size (not a recursive total); the UI shows those specially.
    public let byteSize: Int64
    public let modificationDate: Date
    public let creationDate: Date
    /// Dotfile, or carrying the `UF_HIDDEN` BSD flag.
    public let isHidden: Bool
    /// POSIX permission bits (`mode & 0o777`).
    public let permissions: UInt16
    /// Owning user id (`st_uid`). Free on a local listing — the `stat` already read it — and the
    /// value the attributes panel and `AttributePrivilege` need to answer "do I own this file?"
    /// (PLAN.md §M14 Slice 3). Zero for a backend with no POSIX ownership (archives, remotes).
    public let ownerID: UInt32
    /// Owning group id (`st_gid`); same provenance as ``ownerID``.
    public let groupID: UInt32
    /// The raw BSD file flags word (`st_flags`) — the same read that already yields ``isHidden`` and
    /// ``isDataless``. Kept whole here so the attributes panel can show and edit the individual flags
    /// (Finder's "Locked" is `UF_IMMUTABLE`) without a second `stat`. Zero where a backend has none.
    public let flags: UInt32
    /// Inode number — reserved for future rename/identity tracking across refreshes.
    public let inode: UInt64
    /// The raw text a symlink points at (unresolved), else `nil`.
    public let symlinkDestination: String?
    /// The resolved kind of a symlink's target, or `nil` if the entry is not a
    /// symlink *or* the symlink is broken.
    public let symlinkTargetKind: Kind?
    /// The file carries `SF_DATALESS`: its name, size and dates are real, but none of its
    /// bytes are on this disk — a cloud provider will materialize them on first read
    /// (PLAN.md §M9 "dataless placeholder awareness").
    ///
    /// This is what an evicted iCloud file looks like on macOS today. It is *not* the
    /// `.<name>.icloud` stub of older releases: probed 2026-07-21 with `brctl evict`, the entry
    /// keeps its real name and its full logical `byteSize` while `st_blocks` is zero, so a
    /// listing that ignores this flag reports the file as present and complete.
    ///
    /// The flag matters beyond a badge: reading one byte blocks the calling thread for as long
    /// as the download takes (measured 1.1 s for 200 KB), so any byte-touching sweep — the
    /// recursive sizer, content search, byte-compare — must consult this before it opens
    /// anything, or it silently pulls the user's whole cloud drive down.
    public let isDataless: Bool
    /// The server's entity tag for this row, when the listing carried one — S3's `<ETag>` today,
    /// `nil` for every other backend and for every folder row.
    ///
    /// It exists for one question: whether the object on the server is still the one that was
    /// downloaded (``RemoteFileRevision``). Size and time can only ever be an *absence* of
    /// evidence — a rewrite that kept the length inside one second's resolution is invisible to
    /// both — where a matching tag is proof, which is why it changes that comparison's rule rather
    /// than joining it. Free here: it arrives in the same `ListObjectsV2` response the row is
    /// already built from, so no verb pays for it.
    ///
    /// Opaque, and compared only against another reading of *the same object* — an AWS tag is an
    /// MD5 for a single-part upload and a digest-of-digests with a `-<parts>` suffix for a
    /// multipart one, so it says nothing about content two objects share and must never be read as
    /// a checksum of the bytes.
    public let entityTag: String?

    public init(
        path: VFSPath,
        name: String,
        kind: Kind,
        byteSize: Int64,
        modificationDate: Date,
        creationDate: Date,
        isHidden: Bool,
        permissions: UInt16,
        ownerID: UInt32 = 0,
        groupID: UInt32 = 0,
        flags: UInt32 = 0,
        inode: UInt64,
        symlinkDestination: String? = nil,
        symlinkTargetKind: Kind? = nil,
        isDataless: Bool = false,
        entityTag: String? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.byteSize = byteSize
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.isHidden = isHidden
        self.permissions = permissions
        self.ownerID = ownerID
        self.groupID = groupID
        self.flags = flags
        self.inode = inode
        self.symlinkDestination = symlinkDestination
        self.symlinkTargetKind = symlinkTargetKind
        self.isDataless = isDataless
        self.entityTag = entityTag
    }

    public var id: VFSPath { path }

    public var isDirectory: Bool { kind == .directory }

    /// Treated as a directory for grouping and navigation — a real directory, or a
    /// symlink that resolves to one.
    public var isDirectoryLike: Bool {
        kind == .directory || (kind == .symlink && symlinkTargetKind == .directory)
    }

    /// Filename extension using platform semantics (empty for dotfiles and
    /// trailing-dot names), e.g. "gz" for "archive.tar.gz".
    public var fileExtension: String {
        (name as NSString).pathExtension
    }

    /// Filename without its extension.
    public var baseName: String {
        (name as NSString).deletingPathExtension
    }

    /// What a backend puts in a date field it has no answer for.
    ///
    /// Several already do — an S3 "folder" is a common prefix and not an object, so it has no
    /// `LastModified` at all; an FTP or archive *root* is synthesized rather than listed; and a
    /// timestamp in an unrecognized shape parses to nothing. Every one of them reached for
    /// `.distantPast`, which is the right value and was the wrong *name*: nothing said it meant
    /// "unknown", so the renderer formatted it and drew **01.01.1, 02:02** in the Date column —
    /// a date, in a column of dates, for a row that has none. Naming it is what lets one check at
    /// the display layer cover every producer, present and future.
    public static let unknownDate = Date.distantPast

    /// Whether ``modificationDate`` is a real timestamp rather than ``unknownDate``.
    public var hasModificationDate: Bool { modificationDate != Self.unknownDate }

    /// Whether the name this row shows is the name of the thing at its ``path``.
    ///
    /// True of every row this project produces but one, which is what makes it worth asking:
    /// ``ICloudDrive/libraryRow(for:stat:)`` puts an **app's** name over its `Documents` folder, and
    /// its own doc comment calls that out as the single place where name and path disagree. So a row
    /// reading "Pages" is a folder called `Documents`, and offering to rename it offers to rename
    /// something the user is not looking at — under a name that is not the one they would be
    /// editing.
    ///
    /// It is the honest form of a rule that used to be spelled `!isVirtualDirectory`. That gate was
    /// right about the app rows and wrong about everything standing beside them: a loose file in the
    /// merged iCloud listing, a search hit, a row inside an expanded folder in either — all of them
    /// are ordinary files wearing their own names, and all of them were refused because the
    /// *container* they were drawn in is synthetic. What a rename needs is a row whose name it can
    /// edit and a directory that can perform it, and neither question is about the pane.
    public var nameMatchesPath: Bool { name == path.lastComponent }

    /// The same item under a new name in the same directory.
    ///
    /// Everything else is carried over untouched, because a rename changes nothing else: the size,
    /// the dates, the inode and the cloud state are the same file's. That is what makes this cheap
    /// enough to use where re-`stat`ing would be a network round trip.
    ///
    /// The caller is a listing that cannot re-gather itself — a search snapshot, whose whole
    /// contract is that it keeps the hits it was given (`PanelViewController+Tree` says so where it
    /// refuses to re-list a results root). A hit the app has just renamed is still that hit, so the
    /// row is substituted rather than dropped or left showing a name that is no longer on disk.
    public func renamed(to newName: String) -> FileEntry {
        FileEntry(
            path: (path.parent ?? path).appending(newName),
            name: newName,
            kind: kind,
            byteSize: byteSize,
            modificationDate: modificationDate,
            creationDate: creationDate,
            isHidden: isHidden,
            permissions: permissions,
            inode: inode,
            symlinkDestination: symlinkDestination,
            symlinkTargetKind: symlinkTargetKind,
            isDataless: isDataless
        )
    }
}
