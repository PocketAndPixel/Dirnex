import Foundation

/// `/Albums` (PLAN.md §M28 Slice 3): the albums and folders a person made in Photos, as folders, and
/// each album's originals as rows named by the same rules as a month's.
///
/// **A path is resolved by walking.** Nothing in `/Albums/Trips/Lisbon` says whether `Lisbon` is an
/// album inside a folder `Trips` or a photo inside an album `Trips` — Photos lets both exist side by
/// side — so each name is looked up among its parent's children, a level at a time. A level is one
/// fetch (0.5–1.4 ms, measured 2026-09-13) and is cached against the change token like the rows, so
/// copying 300 photos out of an album walks the library once rather than 300 times.
///
/// A photo in two albums is a row in both, and in its month: an album holds the library's originals,
/// not copies of them.
extension PhotosBackend {
    /// What a path below `/Albums` turned out to be.
    enum AlbumsItem {
        case folder(PhotosCollection)
        case album(PhotosCollection)
        case original(PhotosRow)
    }

    func resolve(_ names: [String], at path: VFSPath) throws -> AlbumsItem {
        var parent: String?
        for (index, name) in names.enumerated() {
            let level = try collections(inFolder: parent, at: path)
            guard let match = level.first(where: { $0.name == name }) else { break }
            let collection = match.collection
            let remaining = names.count - index - 1
            switch (collection.kind, remaining) {
            case (.folder, 0):
                return .folder(collection)
            case (.folder, _):
                parent = collection.identifier
            case (.album, 0):
                return .album(collection)
            case (.album, 1):
                let rows = try albumContents(collection, at: path).rows
                guard let row = rows.first(where: { $0.name == names[index + 1] }) else {
                    throw VFSError.notFound(path)
                }
                return .original(row)
            case (.album, _):
                throw VFSError.notFound(path)
            }
        }
        throw VFSError.notFound(path)
    }

    // MARK: - Listing

    /// `/Albums` itself, which exists only while the library holds an album or a folder — the rule a
    /// year or a month follows, where an empty *album* does exist, since somebody made it.
    func albumsListing(at path: VFSPath) throws -> [FileEntry] {
        let level = try collections(inFolder: nil, at: path)
        guard !level.isEmpty else { throw VFSError.notFound(path) }
        return level.map { collectionEntry($0.collection, at: path.appending($0.name)) }
    }

    func albumsListing(of item: AlbumsItem, at path: VFSPath) throws -> [FileEntry] {
        switch item {
        case let .folder(folder):
            return try collections(inFolder: folder.identifier, at: path).map {
                collectionEntry($0.collection, at: path.appending($0.name))
            }
        case let .album(album):
            let rows = try albumContents(album, at: path).rows
            return rows.map { entry(for: $0, at: path.appending($0.name)) }
        case .original:
            throw VFSError.notADirectory(path)
        }
    }

    func albumsEntry(at path: VFSPath) throws -> FileEntry {
        guard try !collections(inFolder: nil, at: path).isEmpty else { throw VFSError.notFound(path) }
        return directoryEntry(at: path, name: albumsTitle, span: DateSpan())
    }

    func albumsEntry(for item: AlbumsItem, at path: VFSPath) -> FileEntry {
        switch item {
        case let .folder(collection), let .album(collection):
            collectionEntry(collection, at: path)
        case let .original(row):
            entry(for: row, at: path)
        }
    }

    /// An album's dates are the oldest and newest capture the library reports for it, so sorting by
    /// date orders albums by the photographs in them. A folder has none.
    private func collectionEntry(_ collection: PhotosCollection, at path: VFSPath) -> FileEntry {
        directoryEntry(
            at: path,
            name: path.lastComponent,
            span: DateSpan(oldest: collection.oldestCapture, newest: collection.newestCapture)
        )
    }

    // MARK: - Reading, from the cache while the token holds

    /// One level of albums and folders, named — the top of the library when `identifier` is `nil`.
    func collections(
        inFolder identifier: String?,
        at path: VFSPath
    ) throws -> [PhotosNamedCollection] {
        let token = transport.changeToken()
        if let token, let cached = cache.collections(inFolder: identifier, token: token) { return cached }
        let named = try layout.named(
            mapping(path) { try transport.collections(inFolder: identifier) }
        )
        if let token { cache.store(named, inFolder: identifier, token: token) }
        return named
    }

    /// An album's rows. The token is read before the fetch, as for a month, so a change landing during
    /// it is stored under the old token and the next caller reads again.
    private func albumContents(_ album: PhotosCollection, at path: VFSPath) throws -> PhotosFolderContents {
        let key = PhotosCacheKey.album(album.identifier)
        let token = transport.changeToken()
        if let token, let cached = cache.contents(of: key, token: token) { return cached }
        let members = try mapping(path) { try transport.assets(inAlbum: album.identifier) }
        let resources = members.isEmpty
            ? [:]
            : try mapping(path) { try transport.resources(ofAssets: members.map(\.identifier)) }
        let contents = PhotosFolderContents(
            rows: layout.rows(for: members, resources: resources),
            isPresent: true
        )
        if let token { cache.store(contents, of: key, token: token) }
        return contents
    }
}
