import Foundation

/// One row's worth of a Dirnex clipboard copy or drag: **where the file is**, plus the handful of
/// facts `CopyEngine` reads off a source entry (PLAN.md §M23).
///
/// The pasteboard has only ever carried `file://` URLs, which is why ⌘C and drag-out have been
/// local-only since M1 — a row on a server, in a bucket or inside an archive has no such URL, so
/// the gestures were refused rather than made to work. This is the carrier that fixes that: a
/// `VFSPath` names any backend, and the app writes this alongside the file URL (for a local row) or
/// instead of it (for everything else).
///
/// **One payload per pasteboard *item*, never a list in one item.** A multi-row drag is N items by
/// AppKit's construction — `pasteboardWriterForRow` is asked once per row — and a board-level
/// `data(forType:)` returns only the **first** item's data (probed 2026-08-26). A reader written the
/// obvious way therefore drops every row but one, silently, and a two-row drag is the smallest case
/// that shows it. Encoding one row per item makes the clipboard write the same shape as the drag,
/// so there is one reader rather than two that can drift.
///
/// **It is a snapshot, and deliberately so.** Carrying the fields means a paste of twenty objects
/// costs *no* round trips, where re-`stat`ing each path would cost one apiece — 0.6 s each on S3, so
/// a twelve-second stall before the job even appears. Staleness is the obvious objection, and the
/// answer is that F5 already hands the queue entries straight out of the pane's listing, which are
/// exactly as old; nothing here is staler than what shipped. The engine re-reads what it must (it
/// copies metadata by *path*, not from the entry) and reports a vanished source per item.
public struct PasteboardPayload: Sendable, Hashable, Codable {
    /// The format this build writes. A pasteboard outlives the app that filled it — the user can
    /// copy in one version and paste after an update — so a payload from a future build decodes to
    /// `nil` and the reader falls back to file URLs rather than guessing at fields it does not know.
    public static let currentVersion = 1

    /// The type name the app registers with `NSPasteboard`. It lives here, beside the encoding it
    /// describes, so the writer and the reader cannot name two different strings.
    public static let typeIdentifier = "com.dirnex.locations"

    public let version: Int
    public let path: VFSPath
    public let name: String
    public let kind: FileEntry.Kind
    public let byteSize: Int64
    /// The raw link text for a symlink — what `CopyEngine` recreates rather than following.
    public let symlinkDestination: String?

    public init(
        version: Int = PasteboardPayload.currentVersion,
        path: VFSPath,
        name: String,
        kind: FileEntry.Kind,
        byteSize: Int64,
        symlinkDestination: String? = nil
    ) {
        self.version = version
        self.path = path
        self.name = name
        self.kind = kind
        self.byteSize = byteSize
        self.symlinkDestination = symlinkDestination
    }

    /// Snapshot `entry` for the pasteboard.
    public init(_ entry: FileEntry) {
        self.init(
            path: entry.path,
            name: entry.name,
            kind: entry.kind,
            byteSize: entry.byteSize,
            symlinkDestination: entry.symlinkDestination
        )
    }

    /// Rebuild the entry a transfer needs.
    ///
    /// The fields this cannot know are given the same neutral values a synthesized row uses
    /// elsewhere — `FileEntry.unknownDate`, no permissions, inode 0 — rather than plausible
    /// invented ones, because the only consumer is the copy engine and it reads none of them. A
    /// caller that needs a *real* stat (Get Info, an attribute edit) must go and take one; this is
    /// a transfer's source, not a listing's row.
    public var entry: FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: kind,
            byteSize: byteSize,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: name.hasPrefix("."),
            permissions: 0,
            inode: 0,
            symlinkDestination: symlinkDestination
        )
    }

    // MARK: - Wire format

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case backend = "b"
        case path = "p"
        case name = "n"
        case kind = "k"
        case byteSize = "s"
        case symlinkDestination = "l"
    }

    /// `FileEntry.Kind` has no raw value, and giving it one to satisfy this would put a wire format
    /// on a type forty other files read. The mapping lives here instead, where it is the payload's
    /// business and an unrecognized string is a decode failure rather than a wrong kind.
    private enum WireKind: String, Codable {
        case file = "f"
        case directory = "d"
        case symlink = "l"
        case other = "o"

        init(_ kind: FileEntry.Kind) {
            switch kind {
            case .file: self = .file
            case .directory: self = .directory
            case .symlink: self = .symlink
            case .other: self = .other
            }
        }

        var kind: FileEntry.Kind {
            switch self {
            case .file: .file
            case .directory: .directory
            case .symlink: .symlink
            case .other: .other
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        path = VFSPath(
            backend: VFSBackendID(try container.decode(String.self, forKey: .backend)),
            path: try container.decode(String.self, forKey: .path)
        )
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(WireKind.self, forKey: .kind).kind
        byteSize = try container.decode(Int64.self, forKey: .byteSize)
        symlinkDestination = try container.decodeIfPresent(String.self, forKey: .symlinkDestination)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(path.backend.rawValue, forKey: .backend)
        try container.encode(path.path, forKey: .path)
        try container.encode(name, forKey: .name)
        try container.encode(WireKind(kind), forKey: .kind)
        try container.encode(byteSize, forKey: .byteSize)
        try container.encodeIfPresent(symlinkDestination, forKey: .symlinkDestination)
    }

    /// The bytes to put on one pasteboard item, or `nil` if the payload cannot be encoded at all.
    ///
    /// Non-throwing on purpose: the one caller is building a pasteboard item, where the honest
    /// response to an unencodable row is to omit it — the row then behaves exactly as it did before
    /// this type existed. Nothing about a drag is worth an error dialog.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Read one item's payload back, or `nil` for anything this build cannot use: not our JSON at
    /// all (another app may write the same type name), or a version from a newer Dirnex.
    ///
    /// `nil` is a *fallback signal*, never an error — the reader tries file URLs next, which is what
    /// makes a foreign board and a stale board behave the same as they always have.
    public static func decode(_ data: Data) -> PasteboardPayload? {
        guard let payload = try? JSONDecoder().decode(PasteboardPayload.self, from: data),
              payload.version <= currentVersion else { return nil }
        return payload
    }
}
