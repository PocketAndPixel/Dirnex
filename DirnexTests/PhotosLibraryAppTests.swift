import DirnexCore
import Foundation
import Photos
import Testing

@testable import Dirnex

/// A stand-in library holding the probe library's Live Photo (docs/NOTES.md ▸ iCloud Photos). The
/// core's `FakePhotosLibrary` is not visible from the app target, and nothing here needs more.
private struct StubPhotosLibrary: PhotosLibraryTransport {
    /// Captured 2023-04-30T14:04:12Z.
    static let livePhoto = PhotosAsset(
        identifier: "0D2C4C49-84F5-4E98-A5BB-211550FCD57E/L0/001",
        captureDate: Date(timeIntervalSince1970: 1_682_863_452)
    )

    func assets(capturedIn interval: DateInterval?) throws -> [PhotosAsset] {
        guard let date = Self.livePhoto.captureDate, interval.map({ $0.contains(date) }) ?? true else {
            return []
        }
        return [Self.livePhoto]
    }

    func resources(ofAssets identifiers: [String]) throws -> [String: [PhotosResource]] {
        guard identifiers.contains(Self.livePhoto.identifier) else { return [:] }
        return [Self.livePhoto.identifier: [
            PhotosResource(kind: .photo, originalFilename: "IMG_0089.HEIC", byteSize: 1_467_349),
            PhotosResource(kind: .pairedVideo, originalFilename: "IMG_0089.MOV", byteSize: 4_820_568)
        ]]
    }

    func changeToken() -> Data? {
        nil
    }

    func export(
        _: PhotosResource,
        ofAsset _: String,
        toLocalPath _: String,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws {
        throw PhotosLibraryError.notAuthorized
    }
}

/// The Photos library wired into the app (PLAN.md §M28 Slice 2): the pane's backend reaching it,
/// the writes it refuses, the sentence a refused grant gets, the names people read, and a tab that
/// comes back after a relaunch. What PhotoKit itself answers is verified live, not here.
@Suite("Photos library in the app")
struct PhotosLibraryAppTests {
    private let backend = CompositeBackend(
        local: LocalBackend(),
        photos: PhotosBackend(
            transport: StubPhotosLibrary(),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            undatedTitle: PhotosPresentation.undatedTitle
        )
    )

    private func path(_ raw: String) -> VFSPath {
        VFSPath(backend: .photos, path: raw)
    }

    @Test("the pane's backend routes a Photos path to the library")
    func routing() throws {
        #expect(try backend.listDirectory(at: path("/")).map(\.name) == ["2023"])
        #expect(
            try backend.listDirectory(at: path("/2023/2023-04")).map(\.name)
                == ["IMG_0089.HEIC", "IMG_0089.MOV"]
        )
        #expect(try backend.stat(at: path("/2023/2023-04/IMG_0089.MOV")).byteSize == 4_820_568)
    }

    @Test("a Photos path is read-only, so every write grays out")
    func capabilities() {
        let capabilities = backend.capabilities(for: path("/2023/2023-04"))
        #expect(capabilities == .read)
        #expect(capabilities.deleteStrategy == .unsupported)
    }

    /// Language-independent on purpose, like `PermissionSentenceTests`: the app test target inherits
    /// the developer's `AppleLanguages` pin, so what is asserted is which branch was taken.
    @Test("a refused grant gets its own sentence, not the server's and not Full Disk Access's")
    func permissionSentence() {
        let photos = VFSErrorText.sentence(for: VFSError.permissionDenied(path("/")))
        let server = VFSErrorText.sentence(
            for: VFSError.permissionDenied(
                VFSPath(backend: .sftp(SFTPLocation(host: "srv", username: "oleg")), path: "/")
            )
        )
        let local = VFSErrorText.sentence(
            for: VFSError.permissionDenied(.local(NSHomeDirectory() + "/Documents/report.pdf"))
        )
        #expect(photos != server)
        #expect(photos != local)
    }

    @Test("the root, the undated folder and a month are named where a person reads them")
    func names() {
        #expect(path("/").backendRootTitle == PhotosPresentation.libraryTitle)
        #expect(path("/").displayName == PhotosPresentation.libraryTitle)
        #expect(path("/Undated").displayName == PhotosPresentation.undatedTitle)
        #expect(path("/2026/2026-08").displayName == "2026-08")
    }

    @MainActor
    @Test("a Photos tab comes back after a relaunch, with nothing to reconnect")
    func restore() {
        let month = path("/2023/2023-04")
        let restored = PanelViewController.restoredTabs(
            from: PersistedPane(
                tabs: [PersistedTab(path: month, sort: .default, columns: nil, endpoint: nil)],
                activeIndex: 0
            )
        )
        #expect(restored.map(\.panel.path) == [month])
        #expect(restored.first?.pendingConnection == nil)
    }

    @MainActor
    @Test("the sidebar remembers the Photos row's position under a literal of its own")
    func sidebarOrderIdentity() {
        #expect(SidebarViewController.orderIdentity(of: .photos) == "photos")
    }

    @Test("PhotoKit's resource types map onto originals, and the rest keep their raw value")
    func resourceKinds() {
        #expect(PhotoKitLibrary.kind(of: .photo) == .photo)
        #expect(PhotoKitLibrary.kind(of: .video) == .video)
        #expect(PhotoKitLibrary.kind(of: .pairedVideo) == .pairedVideo)
        #expect(PhotoKitLibrary.kind(of: .alternatePhoto) == .alternatePhoto)
        #expect(PhotoKitLibrary.kind(of: .fullSizePhoto) == .derived(rawValue: 5))
        #expect(PhotoKitLibrary.kind(of: .adjustmentData) == .derived(rawValue: 7))
    }
}
