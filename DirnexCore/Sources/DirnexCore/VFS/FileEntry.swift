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
    /// Inode number — reserved for future rename/identity tracking across refreshes.
    public let inode: UInt64
    /// The raw text a symlink points at (unresolved), else `nil`.
    public let symlinkDestination: String?
    /// The resolved kind of a symlink's target, or `nil` if the entry is not a
    /// symlink *or* the symlink is broken.
    public let symlinkTargetKind: Kind?

    public init(
        path: VFSPath,
        name: String,
        kind: Kind,
        byteSize: Int64,
        modificationDate: Date,
        creationDate: Date,
        isHidden: Bool,
        permissions: UInt16,
        inode: UInt64,
        symlinkDestination: String? = nil,
        symlinkTargetKind: Kind? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.byteSize = byteSize
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.isHidden = isHidden
        self.permissions = permissions
        self.inode = inode
        self.symlinkDestination = symlinkDestination
        self.symlinkTargetKind = symlinkTargetKind
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
