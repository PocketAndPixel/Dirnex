import Foundation
import Testing

@testable import DirnexCore

/// `/Albums` (PLAN.md §M28 Slice 3), against a fake holding the albums and folders the probe library
/// held on 2026-09-13 — two `Lisbon`s at different depths, two `Rainbow`s and a folder and an album
/// both called `Trips` at the top, an empty album, and a title with a slash in it.
@Suite("Photos backend: albums")
struct PhotosAlbumsTests {
    private func library() -> FakePhotosLibrary {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        library.install(PhotosProbeLibrary.albums)
        return library
    }

    private func backend(_ library: FakePhotosLibrary, albumsTitle: String = "Albums") -> PhotosBackend {
        PhotosBackend(
            transport: library,
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            albumsTitle: albumsTitle
        )
    }

    private func path(_ raw: String) -> VFSPath {
        VFSPath(backend: .photos, path: raw)
    }

    // MARK: - Where albums are

    @Test("the root lists Albums beside the years, under the title it is handed, and reads no names")
    func rootFolder() throws {
        let library = library()
        let photos = backend(library, albumsTitle: "Альбомы")
        let entries = try photos.listDirectory(at: path("/"))

        let albums = try #require(entries.first { $0.path == path("/Albums") })
        #expect(albums.name == "Альбомы")
        #expect(albums.kind == .directory)
        #expect(albums.hasModificationDate == false)
        #expect(try photos.stat(at: path("/Albums")).name == "Альбомы")
        #expect(library.albumRequests.isEmpty)
        #expect(library.resourceRequests.isEmpty)
    }

    @Test("a library with no albums and no folders has no Albums folder")
    func noAlbums() throws {
        let photos = backend(FakePhotosLibrary(PhotosProbeLibrary.all))
        #expect(throws: VFSError.notFound(path("/Albums"))) { try photos.stat(at: path("/Albums")) }
        #expect(try photos.listDirectory(at: path("/")).allSatisfy { $0.path != path("/Albums") })
    }

    @Test(
        "Albums lists the top level in the library's order, numbering a title a sibling already has"
    )
    func topLevel() throws {
        let library = library()
        let entries = try backend(library).listDirectory(at: path("/Albums"))

        #expect(
            entries.map(\.name) == [
                "Trips",
                "Rainbow",
                "Empty",
                "Lisbon",
                "Trips (2)",
                "Rainbow (2)",
                "Nature"
            ]
        )
        #expect(entries.map(\.path.path).last == "/Albums/Nature")
        #expect(Set(entries.map(\.kind)) == [.directory])
        // A level is a fetch of albums and folders; no album was opened and no name was read.
        #expect(library.albumRequests.isEmpty)
        #expect(library.resourceRequests.isEmpty)
    }

    @Test("an album's dates are its capture range, and a folder and an empty album have none")
    func dates() throws {
        let entries = try backend(library()).listDirectory(at: path("/Albums"))

        let nature = try #require(entries.first { $0.name == "Nature" })
        #expect(nature.creationDate == PhotosProbeLibrary.editedEarlier.asset.captureDate)
        #expect(nature.modificationDate == PhotosProbeLibrary.editedLater.asset.captureDate)
        #expect(try #require(entries.first { $0.name == "Trips (2)" }).hasModificationDate == false)
        #expect(try #require(entries.first { $0.name == "Empty" }).hasModificationDate == false)
    }

    @Test("a folder lists what is inside it, and a slash in a title becomes a colon")
    func folders() throws {
        let photos = backend(library())

        #expect(
            try photos.listDirectory(at: path("/Albums/Trips (2)")).map(\.name) == ["2025", "Lisbon"]
        )
        let nested = try photos.listDirectory(at: path("/Albums/Trips (2)/2025"))
        #expect(nested.map(\.name) == ["Summer:Beach"])
        #expect(nested.first?.path == path("/Albums/Trips (2)/2025/Summer:Beach"))
    }

    // MARK: - What is in an album

    @Test(
        "an album lists its originals by the month's rules: a Live Photo is two rows, an edit's extras none"
    )
    func albumRows() throws {
        let library = library()
        let photos = backend(library)

        let lisbon = try photos.listDirectory(at: path("/Albums/Lisbon"))
        #expect(lisbon.map(\.name) == ["IMG_0089.HEIC", "IMG_0089.MOV", "camphoto_1254324197.jpg"])
        let movie = try #require(lisbon.first { $0.name == "IMG_0089.MOV" })
        #expect(movie.path == path("/Albums/Lisbon/IMG_0089.MOV"))
        #expect(movie.kind == .file)
        #expect(movie.byteSize == 4_820_568)
        #expect(movie.modificationDate == PhotosProbeLibrary.livePhoto.asset.captureDate)

        #expect(
            try photos.listDirectory(at: path("/Albums/Nature")).map(\.name) == [
                "IMG_0042.HEIC",
                "IMG_0043.HEIC"
            ]
        )
    }

    @Test("an empty album exists and lists nothing, without reading any names")
    func emptyAlbum() throws {
        let library = library()
        let photos = backend(library)

        #expect(try photos.listDirectory(at: path("/Albums/Empty")).isEmpty)
        #expect(try photos.stat(at: path("/Albums/Empty")).kind == .directory)
        #expect(library.resourceRequests.isEmpty)
    }

    @Test("a photo in two albums is a row in both, standing for the same original")
    func sharedPhoto() throws {
        let photos = backend(library())
        let top = try photos.stat(at: path("/Albums/Lisbon/IMG_0089.HEIC"))
        let nested = try photos.stat(at: path("/Albums/Trips (2)/Lisbon/IMG_0089.HEIC"))

        #expect(top.byteSize == nested.byteSize)
        #expect(try photos.listDirectory(at: path("/Albums/Trips (2)/Lisbon")).map(\.name)
            == ["IMG_0089.HEIC", "IMG_0089.MOV", "IMG_0222.HEIC", "IMG_0222.MOV"])
    }

    // MARK: - A name alone does not say what it is

    @Test(
        "the same name resolves by what the library holds: the album Trips is empty, the folder is not"
    )
    func albumBesideFolder() throws {
        let photos = backend(library())
        #expect(try photos.listDirectory(at: path("/Albums/Trips")).isEmpty)
        #expect(
            try photos.listDirectory(at: path("/Albums/Trips (2)")).map(\.name) == ["2025", "Lisbon"]
        )
    }

    @Test(
        "a path the library does not hold addresses nothing",
        arguments: [
            "/Albums/Nope", "/Albums/Lisbon/IMG_9999.HEIC", "/Albums/Trips (2)/IMG_0089.HEIC",
            "/Albums/Lisbon/IMG_0089.HEIC/deeper", "/Albums/Trips (3)",
            "/Albums/Trips (2)/2025/Nope"
        ]
    )
    func missing(_ raw: String) {
        let photos = backend(library())
        let missing = path(raw)
        #expect(throws: VFSError.notFound(missing)) { try photos.stat(at: missing) }
        #expect(throws: VFSError.notFound(missing)) { try photos.listDirectory(at: missing) }
    }

    @Test("an original in an album is a file, not a directory")
    func originalIsAFile() throws {
        let photos = backend(library())
        let original = path("/Albums/Trips (2)/2025/Summer:Beach/IMG_0226.MOV")

        let entry = try photos.stat(at: original)
        #expect(entry.kind == .file)
        #expect(entry.byteSize == 2_663_801_226)
        #expect(throws: VFSError.notADirectory(original)) { try photos.listDirectory(at: original) }
    }

    @Test("an album the library has since lost is not found, rather than a failure to read")
    func goneAlbum() {
        let library = library()
        library.albumMembers["0026901F-DC06-49F0-857A-198DD9714C46/L0/040"] = nil
        let photos = backend(library)
        #expect(throws: VFSError.notFound(path("/Albums/Lisbon"))) {
            try photos.listDirectory(at: path("/Albums/Lisbon"))
        }
    }

    // MARK: - Copying out, and the cache

    @Test("copying an original out of an album exports exactly that resource")
    func copyOut() throws {
        let library = library()
        library.bytes["IMG_0042.HEIC"] = Data("nature".utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosAlbumsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = VFSPath.local(directory.appendingPathComponent("IMG_0042.HEIC").path)

        try backend(library).copyFile(
            at: path("/Albums/Nature/IMG_0042.HEIC"),
            to: destination,
            progress: { _ in },
            isCancelled: { false }
        )

        #expect(library.exports == [FakePhotosLibrary.Export(
            identifier: PhotosProbeLibrary.editedEarlier.asset.identifier,
            resource: PhotosProbeLibrary.editedEarlier.resources[0],
            localPath: destination.path
        )])
        #expect(FileManager.default.contents(atPath: destination.path) == Data("nature".utf8))
    }

    @Test("copying a folder of albums as a file is refused as a directory")
    func copyFolderRefused() {
        let photos = backend(library())
        #expect(throws: VFSError.io(path: path("/Albums/Lisbon"), code: EISDIR)) {
            try photos.copyFile(
                at: path("/Albums/Lisbon"),
                to: .local("/tmp/Lisbon"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
    }

    @Test(
        "walking to three originals reads each level and the album's names once while the token holds"
    )
    func cacheHolds() throws {
        let library = library()
        let photos = backend(library)
        for name in ["IMG_0089.HEIC", "IMG_0222.HEIC", "IMG_0222.MOV"] {
            _ = try photos.stat(at: path("/Albums/Trips (2)/Lisbon/\(name)"))
        }
        #expect(library.levelRequests == [nil, "795A9045-9D8D-4090-B94F-A03D9AA47B6E/L0/020"])
        #expect(library.albumRequests.count == 1)
        #expect(library.resourceRequests.count == 1)

        library.token = Data("7013".utf8)
        _ = try photos.stat(at: path("/Albums/Trips (2)/Lisbon/IMG_0089.HEIC"))
        #expect(library.albumRequests.count == 2)
        #expect(library.resourceRequests.count == 2)
    }

    @Test("a change the token reports reaches the next listing of Albums")
    func changeReachesAlbums() throws {
        let library = library()
        let photos = backend(library)
        _ = try photos.listDirectory(at: path("/Albums"))

        library.levels[nil]?.insert(
            PhotosCollection(identifier: "NEW/L0/040", kind: .album, title: "Nature"),
            at: 0
        )
        library.albumMembers["NEW/L0/040"] = []
        library.token = Data("7013".utf8)

        let names = try photos.listDirectory(at: path("/Albums")).map(\.name)
        #expect(names.first == "Nature")
        #expect(names.last == "Nature (2)")
    }
}
