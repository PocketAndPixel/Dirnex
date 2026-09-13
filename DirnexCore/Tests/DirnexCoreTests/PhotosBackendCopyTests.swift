import Foundation
import Testing

@testable import DirnexCore

/// Getting an original's bytes out of the Photos library, and the failures on the way (PLAN.md §M28).
///
/// A suite of its own rather than more of `PhotosBackendTests`, whose listing and month-cache tests
/// already fill SwiftLint's body ceiling.
@Suite("Photos backend: copying out")
struct PhotosBackendCopyTests {
    private func backend(_ library: FakePhotosLibrary) -> PhotosBackend {
        PhotosBackend(transport: library, timeZone: TimeZone(secondsFromGMT: 0) ?? .current)
    }

    private func path(_ raw: String) -> VFSPath {
        VFSPath(backend: .photos, path: raw)
    }

    @Test("copying an original exports exactly that resource to the local destination")
    func copyOut() throws {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        library.bytes["IMG_0089.MOV"] = Data("paired video".utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosBackendCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = VFSPath.local(directory.appendingPathComponent("IMG_0089.MOV").path)

        var reported: Int64 = 0
        try backend(library).copyFile(
            at: path("/2023/2023-04/IMG_0089.MOV"),
            to: destination,
            progress: { reported += $0 },
            isCancelled: { false }
        )

        #expect(library.exports == [FakePhotosLibrary.Export(
            identifier: PhotosProbeLibrary.livePhoto.asset.identifier,
            resource: PhotosProbeLibrary.livePhoto.resources[1],
            localPath: destination.path
        )])
        #expect(FileManager.default.contents(atPath: destination.path) == Data("paired video".utf8))
        #expect(reported == 12)
    }

    @Test("the library is read-only, so a copy into it is refused")
    func readOnly() {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        let photos = backend(library)

        #expect(photos.capabilities == .read)
        #expect(photos.capabilities.deleteStrategy == .unsupported)
        #expect(throws: VFSError.unsupported(.copyFile)) {
            try photos.copyFile(
                at: .local("/tmp/IMG_9999.JPG"),
                to: path("/2026/2026-08/IMG_9999.JPG"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(library.exports.isEmpty)
    }

    @Test("a copy to anywhere but this disk is refused, for the router to stage")
    func remoteDestination() {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        #expect(throws: VFSError.unsupported(.remoteToRemoteCopy)) {
            try backend(library).copyFile(
                at: path("/2023/2023-04/IMG_0089.HEIC"),
                to: VFSPath(backend: VFSBackendID("sftp://oleg@nas:22"), path: "/IMG_0089.HEIC"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(library.exports.isEmpty)
    }

    @Test("a cancelled copy asks the library nothing")
    func cancelled() {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        #expect(throws: CancellationError.self) {
            try backend(library).copyFile(
                at: path("/2023/2023-04/IMG_0089.HEIC"),
                to: .local("/tmp/never-written.heic"),
                progress: { _ in },
                isCancelled: { true }
            )
        }
        #expect(library.intervalsAsked.isEmpty)
        #expect(library.exports.isEmpty)
    }

    @Test("a folder is not a file to copy")
    func folderIsNotAFile() {
        let photos = backend(FakePhotosLibrary(PhotosProbeLibrary.all))
        #expect(throws: VFSError.io(path: path("/2026"), code: EISDIR)) {
            try photos.copyFile(
                at: path("/2026"),
                to: .local("/tmp/2026"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
    }

    @Test("a refused grant reads as permission denied on the path that was asked about")
    func notAuthorized() {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        library.failure = .notAuthorized
        let root = path("/")
        #expect(throws: VFSError.permissionDenied(root)) {
            try backend(library).listDirectory(at: root)
        }
    }

    @Test("an original gone from the library by the time it is exported reads as not found")
    func goneDuringExport() {
        let library = FakePhotosLibrary(PhotosProbeLibrary.all)
        library.exportFailure = PhotosLibraryError.itemGone
        let source = path("/2024/2024-10/camphoto_1254324197.jpg")
        #expect(throws: VFSError.notFound(source)) {
            try backend(library).copyFile(
                at: source,
                to: .local("/tmp/never-written.jpg"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
    }
}
