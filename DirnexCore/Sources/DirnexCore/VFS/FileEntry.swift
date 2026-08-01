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
        isDataless: Bool = false
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
}
