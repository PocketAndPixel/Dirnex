import Foundation
import Testing

@testable import DirnexCore

/// The Photos library as a *location* the rest of the app reasons about (PLAN.md §M28 Slice 2):
/// which shared predicates it answers, what a restored tab needs, where its sidebar place points,
/// and how its undated folder is named.
@Suite("Photos library as a location")
struct PhotosLocationTests {
    @Test("Photos is re-listable and not on this disk, and nothing can be copied into it")
    func predicates() {
        #expect(VFSBackendID.photos.isRemoteConnection)
        #expect(VFSBackendID.photos.isPhotos)
        #expect(!VFSBackendID.photos.acceptsUploads)
        #expect(!VFSBackendID.photos.receivesFiles)
        #expect(!VFSBackendID.photos.hasComparableModificationTimes)
        #expect(!VFSBackendID.local.isPhotos)
    }

    @Test("a search inside the library walks it, since Spotlight does not index it")
    func searchWalks() {
        #expect(SearchRoute.forBackend(.photos) == .walk)
    }

    @Test("a Photos tab restores with nothing to check and nothing to connect")
    func restore() {
        let month = VFSPath(backend: .photos, path: "/2026/2026-08")
        #expect(TabRestorePolicy.requirement(for: month, endpoint: nil) == .photosLibrary)
    }

    /// A stored endpoint names a server, and the library is not one — so it is ignored rather than
    /// trusted, whatever a hand-edited session carries beside the tab.
    @Test("an endpoint stored beside a Photos tab is ignored")
    func restoreIgnoresEndpoint() {
        let endpoint = ServerEndpoint.sftp(
            location: SFTPLocation(host: "example.com", username: "oleg"),
            authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
        )
        let root = VFSPath(backend: .photos, path: "/")
        #expect(TabRestorePolicy.requirement(for: root, endpoint: endpoint) == .photosLibrary)
    }

    @Test("the sidebar's Photos place points at the library root")
    func sidebarPlace() {
        #expect(SidebarPlace.photos.path == VFSPath(backend: .photos, path: "/"))
    }

    @Test("the undated folder wears the title it is handed, over a path that stays English")
    func undatedTitle() throws {
        let undated = FakePhotosLibrary.Stored(
            asset: PhotosAsset(identifier: "UNDATED/L0/001", captureDate: nil),
            resources: [PhotosResource(kind: .photo, originalFilename: "scan.png", byteSize: 10)]
        )
        let photos = PhotosBackend(
            transport: FakePhotosLibrary(PhotosProbeLibrary.all + [undated]),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            undatedTitle: "Без даты"
        )

        let folder = try #require(
            photos.listDirectory(at: VFSPath(backend: .photos, path: "/")).first { !$0.nameMatchesPath }
        )
        #expect(folder.name == "Без даты")
        #expect(folder.path == VFSPath(backend: .photos, path: "/Undated"))
        #expect(try photos.stat(at: folder.path).name == "Без даты")
        #expect(try photos.listDirectory(at: folder.path).map(\.name) == ["scan.png"])
    }
}
