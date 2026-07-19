import Foundation

/// A parsed, in-memory table of contents for an archive — the pure, tested heart of
/// `ArchiveBackend`. It turns the verbose listing `bsdtar -tvf` prints (an `ls -l`-style
/// table) into a navigable directory tree, so a panel can browse a zip/tar as folders
/// (PLAN.md §M4 "browse zip/tar/tgz as folders").
///
/// Pure and hermetic: it never spawns a process or touches disk. The app's
/// `ArchiveMounter` runs `bsdtar` off-main and hands the text here, mirroring how the
/// pure `SpotlightQuery` pairs with the I/O-doing `SpotlightSearchRunner`. Keeping the
/// parsing here makes it independently unit-testable against captured real `bsdtar`
/// output, and lets `ArchiveBackend` answer `list`/`stat` without any I/O.
public struct ArchiveTOC: Sendable, Equatable {
    /// One entry inside the archive, backend-agnostic — no `VFSPath`, since the same TOC
    /// can back an `ArchiveBackend` under any id. The backend wraps these into `FileEntry`
    /// with the archive-scoped path.
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let kind: FileEntry.Kind
        public let byteSize: Int64
        public let modificationDate: Date
        public let symlinkDestination: String?

        public init(
            name: String,
            kind: FileEntry.Kind,
            byteSize: Int64,
            modificationDate: Date,
            symlinkDestination: String? = nil
        ) {
            self.name = name
            self.kind = kind
            self.byteSize = byteSize
            self.modificationDate = modificationDate
            self.symlinkDestination = symlinkDestination
        }
    }

    /// Immediate children keyed by their containing directory's normalized inner path
    /// ("/" = archive root). A directory with no children still appears as an empty array
    /// once it is a known directory.
    private let childrenByDirectory: [String: [Entry]]
    /// Every inner path known to be a directory — explicit `folder/` lines and the
    /// intermediate directories synthesized from a deep entry like `a/b/c.txt`. Always
    /// contains the root "/".
    private let directoryPaths: Set<String>

    /// Parse the text `bsdtar -tvf <archive>` prints. Malformed lines are skipped, tar's
    /// leading `./` is stripped, and any intermediate directory an entry implies but the
    /// archive didn't list explicitly is synthesized so the tree is always fully walkable.
    public init(verboseListing text: String) {
        let parsed = ArchiveTOCParser.parse(text)
        childrenByDirectory = parsed.children
        directoryPaths = parsed.directories
    }

    /// Direct constructor for tests and callers that already have a tree.
    init(childrenByDirectory: [String: [Entry]], directoryPaths: Set<String>) {
        self.childrenByDirectory = childrenByDirectory
        self.directoryPaths = directoryPaths.union(["/"])
    }

    /// Immediate children of the inner directory `path` ("/" = archive root), unsorted —
    /// the panel's `DirectoryModel` sorts. Empty for a leaf directory or an unknown path.
    public func children(inDirectory path: String) -> [Entry] {
        childrenByDirectory[normalize(path)] ?? []
    }

    /// Whether `path` names a directory inside the archive (the root always does).
    public func isDirectory(atInnerPath path: String) -> Bool {
        directoryPaths.contains(normalize(path))
    }

    /// The entry at an inner path, or `nil` if nothing lives there. The root reports a
    /// synthetic directory entry named "/", so `stat` on an archive root succeeds.
    public func entry(atInnerPath path: String) -> Entry? {
        let normalized = normalize(path)
        if normalized == "/" {
            return Entry(name: "/", kind: .directory, byteSize: 0, modificationDate: .distantPast)
        }
        let parent = parentInnerPath(of: normalized)
        let name = String(normalized.split(separator: "/").last ?? "")
        return childrenByDirectory[parent]?.first { $0.name == name }
    }

    /// No parseable entries — an empty or unreadable archive.
    public var isEmpty: Bool {
        childrenByDirectory.values.allSatisfy(\.isEmpty)
    }

    private func normalize(_ path: String) -> String {
        "/" + path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    private func parentInnerPath(of normalized: String) -> String {
        var components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        components.removeLast()
        return "/" + components.joined(separator: "/")
    }
}
