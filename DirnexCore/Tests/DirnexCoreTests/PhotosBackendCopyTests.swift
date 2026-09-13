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

    // MARK: - What an export carries

    /// A directory for one test's exports, removed when the test ends.
    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosBackendCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The library file a clone copies from, as the probe found IMG_0089's on 2026-09-13: stored 21
    /// minutes after it was taken, and carrying the two `cpl` markers a long-local original has.
    private func cloningLibrary(_ stored: [FakePhotosLibrary.Stored]) -> FakePhotosLibrary {
        let library = FakePhotosLibrary(stored)
        library.libraryFileDate = PhotosProbeLibrary.date("2023-04-30T14:25:55.000Z")
        library.libraryFileAttributes = [
            "com.apple.cpl.original": Data("Y".utf8),
            "com.apple.cpl.delete": Data("Y".utf8)
        ]
        return library
    }

    private func export(_ raw: String, from library: FakePhotosLibrary, into directory: URL) throws -> VFSPath {
        let destination = VFSPath.local(
            directory.appendingPathComponent((raw as NSString).lastPathComponent).path
        )
        try backend(library).copyFile(
            at: path(raw),
            to: destination,
            progress: { _ in },
            isCancelled: { false }
        )
        return destination
    }

    /// What Photos' own Export Unmodified Original wrote for this asset, measured the same day: a
    /// birth time of the capture date on the photo **and** on its movie.
    @Test("an exported original is born at its capture date, movie and photo alike")
    func bornAtCaptureDate() throws {
        let library = cloningLibrary(PhotosProbeLibrary.all)
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = try #require(PhotosProbeLibrary.livePhoto.asset.captureDate)

        for name in ["IMG_0089.HEIC", "IMG_0089.MOV"] {
            let destination = try export("/2023/2023-04/\(name)", from: library, into: directory)
            let born = try FileAttributeIO.read(at: destination).attributes.creationDate
            #expect(abs(born.timeIntervalSince(captured)) < 0.001, "\(name) born \(born)")
        }
    }

    /// The narrowness control, and the measurement that overturned the plan: Photos' export keeps
    /// the library file's modification time and its `cpl` markers, so stamping the modification time
    /// or stripping the markers would make a Dirnex export differ from the file it is compared with.
    @Test("an export keeps the library file's modification time and its cpl markers")
    func keepsWhatPhotosKeeps() throws {
        let library = cloningLibrary(PhotosProbeLibrary.all)
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try #require(library.libraryFileDate)

        let destination = try export("/2023/2023-04/IMG_0089.HEIC", from: library, into: directory)

        let modified = try FileAttributeIO.read(at: destination).attributes.modificationDate
        #expect(abs(modified.timeIntervalSince(stored)) < 0.001)
        let marker = Data("Y".utf8)
        for name in ["com.apple.cpl.original", "com.apple.cpl.delete"] {
            let value = try ExtendedAttributeIO.value(of: name, at: destination)
            #expect(value == marker, "\(name)")
        }
    }

    @Test("an original with no capture date keeps the birth time the export gave it")
    func undatedKeepsItsBirthTime() throws {
        let undated = FakePhotosLibrary.Stored(
            asset: PhotosAsset(
                identifier: "5E1A7C2D-0000-4000-8000-000000000001/L0/001",
                captureDate: nil
            ),
            resources: [PhotosResource(kind: .photo, originalFilename: "scan.jpg", byteSize: 42)]
        )
        let library = cloningLibrary([undated])
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = try export("/Undated/scan.jpg", from: library, into: directory)

        // Setting the modification time earlier drags the birth time back to it (docs/NOTES.md ▸
        // ACLs and file attributes), so that is the birth time the export left.
        let born = try FileAttributeIO.read(at: destination).attributes.creationDate
        let stored = try #require(library.libraryFileDate)
        #expect(abs(born.timeIntervalSince(stored)) < 0.001)
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
