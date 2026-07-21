import Foundation

/// Identifies a virtual filesystem backend (see PLAN.md §2 "VFS").
///
/// M1 ships only `.local`; archive and SFTP backends (M4/M5) register their own
/// identifiers. Keeping this a distinct type — rather than a bare string — lets
/// `VFSPath` stay backend-agnostic while remaining `Hashable`/`Sendable`.
public struct VFSBackendID: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The local, on-disk filesystem.
    public static let local = VFSBackendID("local")

    /// A virtual, read-only listing of Spotlight search results (PLAN.md §M4 "Search results →
    /// virtual panel listing"). Its entries carry their real `.local` paths — the results are
    /// scattered across on-disk directories — so operating on a result (Quick Look, Copy to the
    /// other pane) reaches the real file; only the *container* path is synthetic, which the app
    /// uses to recognize a results pane and suppress directory-bound behavior (watching,
    /// re-listing, the `..` row, in-place mutations).
    public static let search = VFSBackendID("search")

    /// A virtual listing of the Trash, merged across every volume that has one (PLAN.md §M8
    /// "Trash row"). macOS keeps a separate trash per volume — `~/.Trash` plus each mount's
    /// `.Trashes/<uid>` — and Finder presents them as one place; this is the identity of that
    /// synthetic container.
    ///
    /// Like `.search`, its entries carry their real `.local` paths, so deleting, previewing or
    /// copying one reaches the actual file wherever it is trashed; only the container is synthetic.
    /// Unlike `.search` it is **not read-only**: the app grants a trash path `[.read, .write]`, and
    /// because that set has no `.trash` in it, the existing capability degradation turns F8 into a
    /// confirmed permanent delete — which is the only delete that means anything in here.
    public static let trash = VFSBackendID("trash")

    /// A virtual listing of iCloud Drive as Finder assembles it (PLAN.md §M9 "the merged
    /// app-container view"): the `com~apple~CloudDocs` container's loose files merged with every
    /// iCloud-enabled app's public `Documents` folder, which live as *siblings* of CloudDocs under
    /// `~/Library/Mobile Documents` rather than inside it.
    ///
    /// Shaped exactly like `.trash`: every entry carries its real `.local` path, so stepping into
    /// "Pages" lands in an ordinary local folder and no operation needs a synthetic path space —
    /// only the container is virtual. It carries `[.read, .write]` for the same reason the Trash
    /// does, and one thing more: the merged root has an obvious real home underneath it
    /// (`SidebarLocations.iCloudDrive()`), so creating, pasting and dropping *into* iCloud Drive
    /// land in the CloudDocs container instead of being refused (`PanelViewController.writeDirectory`).
    public static let icloud = VFSBackendID("icloud")

    /// A virtual, read-only browse of a specific on-disk archive as a folder tree
    /// (PLAN.md §M4 "browse zip/tar/tgz as folders"). The archive's real path is encoded
    /// in the id (`archive:/Users/me/pkg.zip`), so a `VFSPath` identifies both *which*
    /// archive and *which* inner entry — the app's composite backend routes on it to the
    /// right mounted `ArchiveBackend`, and every inner location stays a distinct identity.
    public static func archive(forArchiveAt onDiskPath: String) -> VFSBackendID {
        VFSBackendID(archivePrefix + onDiskPath)
    }

    /// The on-disk archive path this id refers to, or `nil` when it is not an archive id.
    public var archivePath: String? {
        rawValue.hasPrefix(Self.archivePrefix)
            ? String(rawValue.dropFirst(Self.archivePrefix.count))
            : nil
    }

    /// Whether this id addresses an archive's virtual contents (vs. `.local`/`.search`).
    public var isArchive: Bool { rawValue.hasPrefix(Self.archivePrefix) }

    private static let archivePrefix = "archive:"

    public var description: String { rawValue }
}

/// A location within a backend: which backend, plus an absolute POSIX-style path
/// inside it.
///
/// Paths are normalized on construction (duplicate slashes collapsed, trailing
/// slash removed, leading slash enforced) so equal locations compare equal — this
/// matters because `VFSPath` is the identity used to re-anchor the cursor after a
/// live FSEvents refresh (PLAN.md §6 "reapplies cursor by identity, not row index").
///
/// This purposely does not resolve `.`/`..` or follow symlinks: that is lexical vs.
/// physical, and the backend owns physical resolution.
public struct VFSPath: Sendable, Hashable, CustomStringConvertible {
    public let backend: VFSBackendID
    /// Absolute, POSIX-style, normalized path within the backend.
    public let path: String

    public init(backend: VFSBackendID, path: String) {
        self.backend = backend
        self.path = VFSPath.normalize(path)
    }

    /// Convenience for the local filesystem: `VFSPath.local("/Users/me")`.
    public static func local(_ path: String) -> VFSPath {
        VFSPath(backend: .local, path: path)
    }

    public var isRoot: Bool { path == "/" }

    /// The final path component, or "/" for the root.
    public var lastComponent: String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "/"
    }

    /// The containing directory, or `nil` at the backend root.
    public var parent: VFSPath? {
        guard !isRoot else { return nil }
        var components = path.split(separator: "/", omittingEmptySubsequences: true)
        components.removeLast()
        return VFSPath(backend: backend, path: "/" + components.joined(separator: "/"))
    }

    /// A child path formed by appending a single name component.
    public func appending(_ component: String) -> VFSPath {
        let base = isRoot ? "" : path
        return VFSPath(backend: backend, path: base + "/" + component)
    }

    /// The chain of locations from the backend root down to and including this path,
    /// in order — the segments a breadcrumb bar renders left-to-right. The root `/` is
    /// always first; for `/Users/oleg` the result is `[/, /Users, /Users/oleg]`.
    public var ancestorsFromRoot: [VFSPath] {
        var chain: [VFSPath] = []
        var current: VFSPath? = self
        while let node = current {
            chain.append(node)
            current = node.parent
        }
        return chain.reversed()
    }

    /// The immediate child of this path lying on the way to `descendant`, or `nil` if
    /// `descendant` is not strictly beneath this path (or lives in another backend).
    ///
    /// Used to land the cursor on the branch you came from when jumping several levels
    /// up via a breadcrumb click: clicking `/Users` while inside `/Users/oleg/Dev`
    /// returns `/Users/oleg`, so the cursor settles on `oleg`.
    public func child(towards descendant: VFSPath) -> VFSPath? {
        guard backend == descendant.backend else { return nil }
        let chain = descendant.ancestorsFromRoot
        guard let index = chain.firstIndex(of: self), index + 1 < chain.count else { return nil }
        return chain[index + 1]
    }

    /// Whether this path *is* `ancestor` or lies strictly beneath it, within the same backend.
    /// Used to recover a pane when the volume it was browsing is unmounted: a pane whose path is
    /// at or under the vanished mount point (`/Volumes/Temp` itself, or `/Volumes/Temp/sub`) is
    /// sent home, while a pane at `/Volumes` — merely alongside it — is left alone.
    public func isSelfOrDescendant(of ancestor: VFSPath) -> Bool {
        guard backend == ancestor.backend else { return false }
        return self == ancestor || ancestor.child(towards: self) != nil
    }

    public var description: String { "\(backend):\(path)" }

    /// Collapse duplicate slashes, drop a trailing slash, and force an absolute
    /// leading slash. `.`/`..` are left intact — resolving them is the backend's job.
    static func normalize(_ raw: String) -> String {
        let components = raw.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + components.joined(separator: "/")
    }
}

// MARK: - Codable

/// Persisted so the undo journal survives relaunch (PLAN.md §M2 "journal survives
/// relaunch"). Decoding routes through the normalizing initializer, so a stored path is
/// re-normalized on the way back in and identity comparisons stay stable.
extension VFSBackendID: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension VFSPath: Codable {
    private enum CodingKeys: String, CodingKey {
        case backend
        case path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            backend: try container.decode(VFSBackendID.self, forKey: .backend),
            path: try container.decode(String.self, forKey: .path)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backend, forKey: .backend)
        try container.encode(path, forKey: .path)
    }
}
