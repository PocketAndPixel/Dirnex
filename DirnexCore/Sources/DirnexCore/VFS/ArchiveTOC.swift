import Foundation

/// A parsed, in-memory table of contents for an archive — the pure, tested heart of
/// `ArchiveBackend`. It turns the verbose listing `bsdtar -tvf` prints (an `ls -l`-style
/// table) into a navigable directory tree, so a panel can browse a zip/tar as folders
/// (PLAN.md §M4 "browse zip/tar/tgz as folders").
///
/// Pure and hermetic: it never spawns a process or touches disk. The app's
/// `ArchiveMounter` runs `bsdtar` off-main and hands the text here, mirroring how the
/// pure `FileQuery` pairs with the I/O-doing `SpotlightSearchRunner`. Keeping the
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
        /// The member's stored mode, or `nil` for a directory this parser had to **synthesize**
        /// because the archive omitted its entry — there is no row to read a mode from.
        public let permissions: UInt16?
        /// Owner and group as `bsdtar` printed them, or `nil` for a synthesized directory.
        ///
        /// Note these change *shape* with the archive format rather than with the tool: a tar stores
        /// `uname`/`gname` and prints `oleg   wheel`, while a zip stores neither and falls back to
        /// the bare numbers `501    0`. Text either way — see ``FileEntry/ownerName``.
        public let ownerName: String?
        public let groupName: String?
        public let symlinkDestination: String?

        public init(
            name: String,
            kind: FileEntry.Kind,
            byteSize: Int64,
            modificationDate: Date,
            permissions: UInt16? = nil,
            ownerName: String? = nil,
            groupName: String? = nil,
            symlinkDestination: String? = nil
        ) {
            self.name = name
            self.kind = kind
            self.byteSize = byteSize
            self.modificationDate = modificationDate
            self.permissions = permissions
            self.ownerName = ownerName
            self.groupName = groupName
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

    /// At least one entry's name did not survive being decoded, so no path built from that row
    /// addresses the member it names.
    ///
    /// This is the *reading* half of ``ArchiveNameEncoding``. A zip written before UTF-8 was usual
    /// stores its names in an OEM code page with the zip's own UTF-8 flag clear, and `bsdtar`
    /// renders them through `vis(3)` — measured 2026-09-09 on the CP866 fixture, under the pinned
    /// `LC_CTYPE=UTF-8` every ordinary archive needs (``ChildProcessLocale``) the row comes back as
    /// a *mix* of octal escapes and raw bytes, `\217` + `a0` + `\255` + `ae e0 a0 ac a0`, which is
    /// not valid UTF-8. ``SubprocessText`` keeps the other ninety-nine rows visible by substituting
    /// U+FFFD rather than answering `nil` for the whole listing, and this is what notices it did.
    ///
    /// So the substitution is the signal, and it is one this type can see and a caller cannot ask
    /// for cheaply: `EncryptedArchiveReader.nameSamples(archiveAt:encoding: nil)` is the *exact*
    /// detector and reads every header of an archive whose names are fine, which is the common case
    /// and the wrong thing to spend on a menu validator. This costs one pass at mount time.
    ///
    /// It is deliberately a question about the **archive**, not about the directory somebody is
    /// standing in: one declaration covers the whole file, so a folder whose own rows happen to be
    /// ASCII must not read as an archive with nothing wrong with it.
    ///
    /// False for the libarchive route, which is the one a declared archive takes —
    /// `archive_entry_pathname_utf8` answers NULL for an unmapped byte rather than substituting, and
    /// that surfaces as ``EncryptedArchiveError/entryNameNotUTF8``. A name a user genuinely typed
    /// U+FFFD into reads as unreadable here, which costs an offer nobody needed and loses nothing.
    public let hasUnreadableNames: Bool

    /// Parse the text `bsdtar -tvf <archive>` prints. Malformed lines are skipped, tar's
    /// leading `./` is stripped, and any intermediate directory an entry implies but the
    /// archive didn't list explicitly is synthesized so the tree is always fully walkable.
    public init(verboseListing text: String) {
        let parsed = ArchiveTOCParser.parse(text)
        self.init(childrenByDirectory: parsed.children, directoryPaths: parsed.directories)
    }

    /// Build from headers libarchive read — the route an archive takes when its names are in a
    /// declared code page, which `bsdtar` cannot be told about (``ArchiveNameEncoding``).
    public init(entries: [EncryptedArchiveReader.Entry]) {
        let parsed = ArchiveTOCParser.parse(entries: entries)
        self.init(childrenByDirectory: parsed.children, directoryPaths: parsed.directories)
    }

    /// Direct constructor for tests and callers that already have a tree.
    init(childrenByDirectory: [String: [Entry]], directoryPaths: Set<String>) {
        self.childrenByDirectory = childrenByDirectory
        self.directoryPaths = directoryPaths.union(["/"])
        // Stored rather than computed: the one caller is a menu validator, which AppKit asks on
        // every menu open, and a scan of a hundred thousand entries there is a cost the pane pays
        // for looking at its own File menu.
        hasUnreadableNames = childrenByDirectory.values.contains { entries in
            entries.contains { $0.name.contains(Self.replacementCharacter) }
        }
    }

    /// What ``SubprocessText/lossyUTF8(_:)`` leaves in place of a byte sequence that is not UTF-8.
    private static let replacementCharacter: Character = "\u{FFFD}"

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
            return Entry(
                name: "/", kind: .directory, byteSize: 0, modificationDate: FileEntry.unknownDate
            )
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
