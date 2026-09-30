import Foundation

/// A `VFSBackend` that browses the system Photos library as folders of originals (PLAN.md §M28):
/// years, then months, then each asset's original files — and beside them `Albums`, the albums and
/// folders a person made, holding the same originals (``PhotosBackend+Albums``).
///
/// **Read-only.** Import, delete and album edits are each a write Photos itself mediates, with its
/// own confirmation, and none of them is in the milestone — so `capabilities` is `.read`, and every
/// write verb keeps the protocol's refusing default.
///
/// **What costs is the name, and the backend is shaped around that.** A root or year listing needs
/// only capture dates, which one fetch answers; a month listing needs every asset's resources, at
/// ~1.1 ms an asset. And turning a *path* back into an asset — a `stat`, or a `copyFile` handed
/// nothing but a path — costs the whole month's names, because the name is the only thing in the
/// path. So each month's and each album's rows are cached against the library's change token, which
/// is cheap to ask before each use: without it, copying 300 photos out of a month of 300 would read
/// the month 300 times.
public struct PhotosBackend: ConnectionScopedBackend {
    let transport: any PhotosLibraryTransport
    public let layout: PhotosLayout
    let cache = PhotosFolderCache()

    /// What the undated folder's row is called. Its path stays `/Undated` whatever this says.
    public let undatedTitle: String
    /// What the albums folder's row is called. Its path stays `/Albums` whatever this says.
    public let albumsTitle: String

    /// - Parameters:
    ///   - timeZone: what months are cut in. The app passes the Mac's own.
    ///   - undatedTitle: the undated folder's name in the running language, drawn over a path that
    ///     stays English because a path is an identity.
    ///   - albumsTitle: the albums folder's name in the running language, for the same reason.
    public init(
        transport: any PhotosLibraryTransport,
        timeZone: TimeZone = .current,
        undatedTitle: String = PhotosLayout.undatedFolderName,
        albumsTitle: String = PhotosLayout.albumsFolderName
    ) {
        self.transport = transport
        layout = PhotosLayout(timeZone: timeZone)
        self.undatedTitle = undatedTitle
        self.albumsTitle = albumsTitle
    }

    public var id: VFSBackendID { .photos }
    public var connectionDescriptor: String { "Photos" }
    public var capabilities: VFSCapabilities { .read }

    // MARK: - Listing

    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try requireOwnBackend(path)
        guard let location = layout.location(of: path) else { throw VFSError.notFound(path) }
        switch location {
        case .root:
            return try yearFolders(at: path)
        case let .folder(.year(year)):
            return try monthFolders(inYear: year, at: path)
        case let .folder(folder):
            let contents = try contents(of: folder, at: path)
            guard contents.isPresent else { throw VFSError.notFound(path) }
            return contents.rows.map { entry(for: $0, at: path.appending($0.name)) }
        case .original:
            throw VFSError.notADirectory(path)
        case .albums:
            return try albumsListing(at: path)
        case let .inAlbums(names):
            return try albumsListing(of: resolve(names, at: path), at: path)
        }
    }

    public func stat(at path: VFSPath) throws -> FileEntry {
        try requireOwnBackend(path)
        guard let location = layout.location(of: path) else { throw VFSError.notFound(path) }
        switch location {
        case .root:
            return directoryEntry(at: path, name: "Photos", span: DateSpan())
        case let .folder(folder):
            let assets = try fetch(layout.interval(of: folder), at: path)
            let members = layout.members(of: folder, among: assets)
            guard !members.isEmpty else { throw VFSError.notFound(path) }
            return folderEntry(folder, span: DateSpan(members))
        case let .original(name, folder):
            return try entry(for: row(named: name, in: folder, at: path), at: path)
        case .albums:
            return try albumsEntry(at: path)
        case let .inAlbums(names):
            return try albumsEntry(for: resolve(names, at: path), at: path)
        }
    }

    private func yearFolders(at path: VFSPath) throws -> [FileEntry] {
        var years: [Int: DateSpan] = [:]
        var hasUndated = false
        for asset in try fetch(nil, at: path) {
            guard let date = asset.captureDate else {
                hasUndated = true
                continue
            }
            years[layout.year(of: date), default: DateSpan()].include(date)
        }
        var entries = years.map { folderEntry(.year($0.key), span: $0.value) }
        if hasUndated { entries.append(folderEntry(.undated, span: DateSpan())) }
        if try !collections(inFolder: nil, at: path).isEmpty {
            entries.append(
                directoryEntry(at: layout.albumsPath, name: albumsTitle, span: DateSpan())
            )
        }
        return entries
    }

    private func monthFolders(inYear year: Int, at path: VFSPath) throws -> [FileEntry] {
        let assets = try fetch(layout.interval(of: .year(year)), at: path)
        var months: [PhotosLayout.Folder: DateSpan] = [:]
        for asset in layout.members(of: .year(year), among: assets) {
            months[layout.month(containing: asset.captureDate), default: DateSpan()]
                .include(asset.captureDate)
        }
        guard !months.isEmpty else { throw VFSError.notFound(path) }
        return months.map { folderEntry($0.key, span: $0.value) }
    }

    // MARK: - Copying out

    /// Export one original to a file on this disk.
    ///
    /// Only that direction exists. A copy *into* the library would be an import, which M28 does not
    /// do; a copy to another remote destination is staged through this disk by the router, which
    /// holds both ends, so here it is the same refusal every remote backend gives on its own.
    public func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        guard source.backend == id else { throw VFSError.unsupported(.copyFile) }
        guard destination.backend == .local else { throw VFSError.unsupported(.remoteToRemoteCopy) }
        let row = try original(at: source)
        try mapping(source) {
            try transport.export(
                row.resource,
                ofAsset: row.assetIdentifier,
                toLocalPath: destination.path,
                progress: progress,
                isCancelled: isCancelled
            )
        }
        stampCaptureDate(of: row, on: destination)
    }

    /// Give an exported original its capture date as its **birth time** — what Photos' own Export
    /// Unmodified Original does, measured 2026-09-13 against the same assets exported both ways
    /// (docs/NOTES.md ▸ iCloud Photos).
    ///
    /// The same measurement decided what this leaves alone, and it overturned the plan. Photos keeps
    /// the library file's modification time, to the nanosecond, because its export is a clone too;
    /// it keeps `com.apple.cpl.original` and `com.apple.cpl.delete`; and it stamps a Live Photo's
    /// movie with the capture date as well as its photo. Moving the modification time or clearing
    /// the `cpl` markers, both of which PLAN.md §M28 Slice 4 had assumed, would have made a Dirnex
    /// export differ from the file a person compares it with. Photos also rewrites the quarantine
    /// with its own name as the agent, which is not imitated: the flag is left as the export wrote it.
    ///
    /// Best-effort, and deliberately so: the bytes are already where they were asked to go, and a
    /// volume that keeps no birth time is no reason to report a finished copy as failed. An original
    /// with no capture date keeps the birth time the export gave it.
    private func stampCaptureDate(of row: PhotosRow, on destination: VFSPath) {
        guard let captureDate = row.captureDate else { return }
        try? FileAttributeIO.setCreationDate(captureDate, at: destination)
    }

    // MARK: - Rows

    /// The original `path` names, wherever in the view it is listed.
    private func original(at path: VFSPath) throws -> PhotosRow {
        switch layout.location(of: path) {
        case let .original(name, folder)?:
            return try row(named: name, in: folder, at: path)
        case let .inAlbums(names)?:
            guard case let .original(row) = try resolve(names, at: path) else {
                throw VFSError.io(path: path, code: EISDIR)
            }
            return row
        case nil:
            throw VFSError.notFound(path)
        default:
            throw VFSError.io(path: path, code: EISDIR)
        }
    }

    private func row(
        named name: String,
        in folder: PhotosLayout.Folder,
        at path: VFSPath
    ) throws -> PhotosRow {
        guard let row = try contents(of: folder, at: path).rows.first(where: { $0.name == name })
        else { throw VFSError.notFound(path) }
        return row
    }

    /// A folder of originals, from the cache while the library's change token still matches.
    ///
    /// The token is read **before** the fetch, so a change landing during it is stored under the old
    /// token and the next caller reads again. With no token there is nothing to trust a cached answer
    /// against, so nothing is cached.
    private func contents(of folder: PhotosLayout.Folder, at path: VFSPath) throws -> PhotosFolderContents {
        let token = transport.changeToken()
        if let token, let cached = cache.contents(of: .period(folder), token: token) { return cached }

        let members = try layout.members(
            of: folder,
            among: fetch(layout.interval(of: folder), at: path)
        )
        let resources = members.isEmpty
            ? [:]
            : try mapping(path) { try transport.resources(ofAssets: members.map(\.identifier)) }
        let contents = PhotosFolderContents(
            rows: layout.rows(for: members, resources: resources),
            isPresent: !members.isEmpty
        )
        if let token { cache.store(contents, of: .period(folder), token: token) }
        return contents
    }

    private func fetch(_ interval: DateInterval?, at path: VFSPath) throws -> [PhotosAsset] {
        try mapping(path) { try transport.assets(capturedIn: interval) }
    }

    // MARK: - Entries

    private func folderEntry(_ folder: PhotosLayout.Folder, span: DateSpan) -> FileEntry {
        let name = folder == .undated ? undatedTitle : layout.name(of: folder)
        return directoryEntry(at: layout.path(of: folder), name: name, span: span)
    }

    /// A folder's dates are its newest and oldest captures, so sorting by date orders years and
    /// months the way the photographs in them run.
    func directoryEntry(at path: VFSPath, name: String, span: DateSpan) -> FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: .directory,
            byteSize: 0,
            modificationDate: span.newest ?? FileEntry.unknownDate,
            creationDate: span.oldest ?? FileEntry.unknownDate,
            isHidden: false,
            permissions: nil,
            inode: 0
        )
    }

    /// One original as a row. Both dates are the capture date: PhotoKit's own modification date moves
    /// whenever Photos touches metadata, so it would sort a library by nothing. A size the library did
    /// not report is drawn as zero.
    func entry(for row: PhotosRow, at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: row.name,
            kind: .file,
            byteSize: row.resource.byteSize ?? 0,
            modificationDate: row.captureDate ?? FileEntry.unknownDate,
            creationDate: row.captureDate ?? FileEntry.unknownDate,
            isHidden: false,
            permissions: nil,
            inode: 0
        )
    }

    /// Normalize a library failure onto the shared `VFSError` vocabulary, naming the path that was
    /// asked about. Anything else — `CancellationError` above all — passes through untouched.
    func mapping<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as PhotosLibraryError {
            switch error {
            case .notAuthorized: throw VFSError.permissionDenied(path)
            case .itemGone: throw VFSError.notFound(path)
            case .failed: throw VFSError.io(path: path, code: EIO)
            }
        }
    }
}

/// The oldest and newest capture dates a folder holds.
struct DateSpan {
    private(set) var oldest: Date?
    private(set) var newest: Date?

    init() {}

    init(_ assets: [PhotosAsset]) {
        for asset in assets { include(asset.captureDate) }
    }

    init(oldest: Date?, newest: Date?) {
        include(oldest)
        include(newest)
    }

    mutating func include(_ date: Date?) {
        guard let date else { return }
        oldest = min(oldest ?? date, date)
        newest = max(newest ?? date, date)
    }
}

/// A folder of originals as one read of the library left it.
struct PhotosFolderContents: Sendable, Hashable {
    let rows: [PhotosRow]
    /// Whether any asset belongs here — a month holding only assets with no originals still exists,
    /// where a month holding nothing does not.
    let isPresent: Bool
}

/// What a cached answer is an answer about.
enum PhotosCacheKey: Hashable {
    /// A year's month, or `Undated`: its rows.
    case period(PhotosLayout.Folder)
    /// An album, by identifier: its rows.
    case album(String)
}

/// Each folder's rows and each level's albums, valid for one change token.
///
/// Bounded crudely, by emptying when full: a session visits a handful of months and albums, and the
/// one thing a cache here must never do is outlive the library it read, which the token already
/// guarantees.
final class PhotosFolderCache: @unchecked Sendable {
    static let capacity = 64

    private let lock = NSLock()
    private var token: Data?
    private var folders: [PhotosCacheKey: PhotosFolderContents] = [:]
    /// Keyed by the folder's identifier, with `nil` for the top of the library.
    private var levels: [String?: [PhotosNamedCollection]] = [:]

    func contents(of key: PhotosCacheKey, token current: Data) -> PhotosFolderContents? {
        lock.lock()
        defer { lock.unlock() }
        guard token == current else { return nil }
        return folders[key]
    }

    func store(_ contents: PhotosFolderContents, of key: PhotosCacheKey, token current: Data) {
        lock.lock()
        defer { lock.unlock() }
        adopt(current)
        if folders[key] == nil, folders.count >= Self.capacity { folders.removeAll() }
        folders[key] = contents
    }

    func collections(inFolder identifier: String?, token current: Data) -> [PhotosNamedCollection]? {
        lock.lock()
        defer { lock.unlock() }
        guard token == current else { return nil }
        return levels[identifier]
    }

    func store(
        _ collections: [PhotosNamedCollection],
        inFolder identifier: String?,
        token current: Data
    ) {
        lock.lock()
        defer { lock.unlock() }
        adopt(current)
        if levels[identifier] == nil, levels.count >= Self.capacity { levels.removeAll() }
        levels[identifier] = collections
    }

    /// Forget everything read under another token. Called with the lock held.
    private func adopt(_ current: Data) {
        guard token != current else { return }
        folders.removeAll()
        levels.removeAll()
        token = current
    }
}
