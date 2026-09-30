import Foundation
import Testing

@testable import DirnexCore

/// The Photos library browsed as folders of originals (PLAN.md §M28), against a fake holding assets
/// the probe library really had.
@Suite("Photos backend")
struct PhotosBackendTests {
    private func backend(_ library: FakePhotosLibrary) -> PhotosBackend {
        PhotosBackend(transport: library, timeZone: TimeZone(secondsFromGMT: 0) ?? .current)
    }

    private func path(_ raw: String) -> VFSPath {
        VFSPath(backend: .photos, path: raw)
    }

    private func undated(_ name: String) -> FakePhotosLibrary.Stored {
        FakePhotosLibrary.Stored(
            asset: PhotosAsset(identifier: "UNDATED-\(name)/L0/001", captureDate: nil),
            resources: [PhotosResource(kind: .photo, originalFilename: name, byteSize: 10)]
        )
    }

    // MARK: - Listing

    @Test("the root lists one folder per year, plus Undated, and reads no names")
    func root() throws {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all + [undated("IMG_0001.JPG")])
        let entries = try backend(library).listDirectory(at: path("/"))

        #expect(entries.map(\.name).sorted() == ["2022", "2023", "2024", "2026", "Undated"])
        #expect(Set(entries.map(\.kind)) == [.directory])
        let year = try #require(entries.first { $0.name == "2022" })
        #expect(year.path == path("/2022"))
        #expect(year.modificationDate == PhotosProbeLibrary.editedLater.asset.captureDate)
        #expect(year.creationDate == PhotosProbeLibrary.editedEarlier.asset.captureDate)
        // Only dates were needed, so the expensive read never happened.
        #expect(library.resourceRequests.isEmpty)
    }

    @Test("a year lists the months that hold something, and reads no names")
    func year() throws {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        let entries = try backend(library).listDirectory(at: path("/2026"))

        #expect(entries.map(\.name) == ["2026-08"])
        #expect(entries.first?.path == path("/2026/2026-08"))
        #expect(library.resourceRequests.isEmpty)
    }

    @Test("a month lists its originals with their sizes and capture dates, from one read of names")
    func month() throws {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        let entries = try backend(library).listDirectory(at: path("/2026/2026-08"))

        #expect(entries.map(\.name) == ["IMG_0222.HEIC", "IMG_0222.MOV", "IMG_0226.MOV"])
        let movie = try #require(entries.last)
        #expect(movie.path == path("/2026/2026-08/IMG_0226.MOV"))
        #expect(movie.kind == .file)
        #expect(movie.byteSize == 2_663_801_226)
        #expect(movie.modificationDate == PhotosProbeLibrary.longVideo.asset.captureDate)
        #expect(movie.creationDate == PhotosProbeLibrary.longVideo.asset.captureDate)
        #expect(movie.permissions == nil)
        #expect(
            library.resourceRequests == [[
                PhotosProbeLibrary.liveAugust.asset.identifier,
                PhotosProbeLibrary.longVideo.asset.identifier
            ]]
        )
    }

    @Test("an asset with no capture date lists under Undated")
    func undatedFolder() throws {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all + [undated("scan.png")])
        let entries = try backend(library).listDirectory(at: path("/Undated"))

        #expect(entries.map(\.name) == ["scan.png"])
        #expect(entries.first?.path == path("/Undated/scan.png"))
        #expect(entries.first?.hasModificationDate == false)
    }

    @Test("a transport that answers wide cannot put a row in the wrong month")
    func wideTransport() throws {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        library.answersWide = true
        let photos = backend(library)

        let august = try photos.listDirectory(at: path("/2026/2026-08")).map(\.name)
        #expect(august == ["IMG_0222.HEIC", "IMG_0222.MOV", "IMG_0226.MOV"])
        #expect(try photos.listDirectory(at: path("/2022")).map(\.name) == ["2022-07"])
        // Only August's two assets were worth the expensive read.
        #expect(library.resourceRequests.last?.count == 2)
    }

    @Test(
        "a folder with nothing in it does not exist",
        arguments: ["/2025", "/2026/2026-07", "/Undated"]
    )
    func emptyFolders(_ raw: String) {
        let photos = backend(FakePhotosLibrary(PhotosProbeLibrary.all))
        let folder = path(raw)
        #expect(throws: VFSError.notFound(folder)) { try photos.listDirectory(at: folder) }
        #expect(throws: VFSError.notFound(folder)) { try photos.stat(at: folder) }
    }

    @Test("a path the layout does not produce is not found, and an original is not a directory")
    func notDirectories() {
        let photos = backend(FakePhotosLibrary(PhotosProbeLibrary.all))
        #expect(throws: VFSError.notFound(path("/Albums"))) { try photos.listDirectory(
            at: path("/Albums")
        ) }
        let original = path("/2023/2023-04/IMG_0089.HEIC")
        #expect(throws: VFSError.notADirectory(original)) { try photos.listDirectory(at: original) }
    }

    @Test("a path from another backend is refused before the library is asked anything")
    func foreignPath() {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        #expect(
            throws: VFSError.unsupported(
                .pathOutsideConnection(path: "local:/Users", connection: "Photos")
            )
        ) {
            try backend(library).listDirectory(at: .local("/Users"))
        }
        #expect(library.intervalsAsked.isEmpty)
    }

    @Test("stat answers the root, a folder and an original by the listing's own rules")
    func stat() throws {
        let photos = backend(FakePhotosLibrary(PhotosProbeLibrary.all))

        #expect(try photos.stat(at: path("/")).kind == .directory)
        let month = try photos.stat(at: path("/2023/2023-04"))
        #expect(month.name == "2023-04")
        #expect(month.modificationDate == PhotosProbeLibrary.livePhoto.asset.captureDate)
        let movie = try photos.stat(at: path("/2023/2023-04/IMG_0089.MOV"))
        #expect(movie.kind == .file)
        #expect(movie.byteSize == 4_820_568)
        let missing = path("/2023/2023-04/IMG_0090.HEIC")
        #expect(throws: VFSError.notFound(missing)) { try photos.stat(at: missing) }
    }

    // MARK: - The month cache

    @Test("a month's names are read once while the library's change token holds")
    func cacheHolds() throws {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        let photos = backend(library)

        _ = try photos.listDirectory(at: path("/2026/2026-08"))
        _ = try photos.stat(at: path("/2026/2026-08/IMG_0222.MOV"))
        _ = try photos.stat(at: path("/2026/2026-08/IMG_0226.MOV"))
        #expect(library.resourceRequests.count == 1)

        library.token = Data("7013".utf8)
        _ = try photos.stat(at: path("/2026/2026-08/IMG_0226.MOV"))
        #expect(library.resourceRequests.count == 2)
    }

    @Test("a change the token reports reaches the next listing")
    func changeReachesListing() throws {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        let photos = backend(library)
        _ = try photos.listDirectory(at: path("/2023/2023-04"))

        library.stored.append(FakePhotosLibrary.Stored(
            asset: PhotosAsset(
                identifier: "NEW/L0/001",
                captureDate: PhotosProbeLibrary.date("2023-04-30T15:00:00.000Z")
            ),
            resources: [PhotosResource(kind: .photo, originalFilename: "IMG_0089.HEIC", byteSize: 5)]
        ))
        library.token = Data("7013".utf8)

        let names = try photos.listDirectory(at: path("/2023/2023-04")).map(\.name)
        #expect(names == ["IMG_0089.HEIC", "IMG_0089.MOV", "IMG_0089 (2).HEIC"])
    }

    @Test(
        "with no change token there is nothing to trust a cached month against, so nothing is cached"
    )
    func noToken() throws {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        library.token = nil
        let photos = backend(library)

        _ = try photos.stat(at: path("/2026/2026-08/IMG_0222.MOV"))
        _ = try photos.stat(at: path("/2026/2026-08/IMG_0226.MOV"))
        #expect(library.resourceRequests.count == 2)
    }
}
