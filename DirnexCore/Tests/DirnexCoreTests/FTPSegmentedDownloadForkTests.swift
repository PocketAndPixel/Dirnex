import Foundation
import Testing

@testable import DirnexCore

/// The fork in front of a segmented FTP download (docs/HISTORY.md ▸ After M19) — which downloads are
/// split at all.
///
/// Four conditions, each excluding a case segments cannot serve: a partial already on disk, no size
/// hint, a file under FTP's own threshold (which is twice S3's, because a segment here is a login),
/// and a connection that has already shown it will not serve a split download.
@Suite("FTP segmented download: the fork")
struct FTPSegmentedDownloadForkTests {
    private static let location = FTPLocation(host: "ftp.example", username: "u")
    private static let mebibyte: Int64 = 1024 * 1024

    @Test("a fresh download of a known, worthwhile size is split")
    func forkSplitsAWorthwhileDownload() throws {
        let transport = FakeFTPTransport()
        transport.fileBytes = Data(count: Int(17 * Self.mebibyte))
        let backend = FTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let destination = directory.appendingPathComponent("clip.mov").path
            try backend.copyFile(
                at: VFSPath(backend: backend.id, path: "/pub/clip.mov"),
                to: .local(destination),
                expectedSize: 17 * Self.mebibyte,
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(transport.segmentRuns == [[1, 2]])
            #expect(transport.downloads.isEmpty)
            #expect(Self.fileSize(destination) == 17 * Self.mebibyte)
        }
    }

    @Test("with no size hint nothing is split, and nothing is asked for one")
    func forkWithoutAHintTakesOneStream() throws {
        let transport = FakeFTPTransport()
        transport.fileBytes = Data(count: Int(17 * Self.mebibyte))
        let backend = FTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            try backend.copyFile(
                at: VFSPath(backend: backend.id, path: "/pub/clip.mov"),
                to: .local(directory.appendingPathComponent("clip.mov").path),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(transport.segmentRuns.isEmpty)
            #expect(transport.downloads.count == 1)
            // The whole point of the hint: a download still costs no `SIZE`.
            #expect(transport.fileSizeQueries.isEmpty)
        }
    }

    @Test("a file under FTP's threshold takes one stream however good the hint is")
    func forkLeavesSmallFilesAlone() throws {
        let transport = FakeFTPTransport()
        let backend = FTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            try backend.copyFile(
                at: VFSPath(backend: backend.id, path: "/pub/note.txt"),
                to: .local(directory.appendingPathComponent("note.txt").path),
                // Over S3's threshold and under FTP's, which is the whole point of two tables.
                expectedSize: 12 * Self.mebibyte,
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(transport.segmentRuns.isEmpty)
            #expect(transport.downloads.count == 1)
        }
    }

    /// A partial on disk takes the resuming route untouched: segments are fetched into files of
    /// their own and have nothing to continue from.
    @Test("a partial already on disk still resumes, in one stream")
    func forkResumesAPartial() throws {
        let transport = FakeFTPTransport()
        transport.remoteFileSizes["/pub/clip.mov"] = 17 * Self.mebibyte
        let backend = FTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let destination = directory.appendingPathComponent("clip.mov").path
            try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: destination))
            try backend.copyFile(
                at: VFSPath(backend: backend.id, path: "/pub/clip.mov"),
                to: .local(destination),
                expectedSize: 17 * Self.mebibyte,
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(transport.segmentRuns.isEmpty)
            #expect(transport.downloads.map(\.resume) == [true])
        }
    }

    /// The latch's whole purpose, from the outside: a connection that has refused once is not asked
    /// again, so the second file costs one stream rather than a doomed run plus a stream.
    @Test("a connection that refused once is not asked again")
    func aRefusedConnectionIsNotAskedAgain() throws {
        let transport = FakeFTPTransport()
        transport.fileBytes = Data(count: Int(17 * Self.mebibyte))
        transport.servesAtMostSegments = 1
        let backend = FTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            for name in ["one.mov", "two.mov"] {
                try backend.copyFile(
                    at: VFSPath(backend: backend.id, path: "/pub/\(name)"),
                    to: .local(directory.appendingPathComponent(name).path),
                    expectedSize: 17 * Self.mebibyte,
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
            // One doomed run in total, and both files fetched whole.
            #expect(transport.segmentRuns.count == 1)
            #expect(transport.downloads.count == 2)
            #expect(Self.fileSize(directory.appendingPathComponent("two.mov").path)
                == 17 * Self.mebibyte)
        }
    }

    // MARK: - Helpers

    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return -1 }
        return size
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-ftpfork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
