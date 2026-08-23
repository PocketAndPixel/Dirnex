import Foundation
import Testing

@testable import DirnexCore

/// What becomes of a segmented SFTP download's pieces, and the fork that decides whether one happens
/// (docs/HISTORY.md ▸ After M19).
///
/// The route's own failure has no equivalent on the other two: an account confined to the `sftp`
/// subsystem answers an exec request **successfully**, with prose where the data should be. So the
/// pieces exist, nothing threw, and only their lengths say anything is wrong — which is why the
/// assembly's length check is load-bearing here rather than defensive.
@Suite("SFTP segmented download: the pieces")
struct SFTPSegmentedDownloadBackendTests {
    private static let location = SFTPLocation(host: "ssh.example", username: "u")
    private static let mebibyte: Int64 = 1024 * 1024

    // MARK: - The backend

    @Test("a segmented download lands the file byte for byte, and cleans up after itself")
    func backendAssemblesTheFile() throws {
        let contents = Data((0..<5000).map { UInt8($0 % 251) })
        let transport = FakeSFTPTransport()
        transport.fileBytes = contents
        let backend = SFTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let destination = directory.appendingPathComponent("clip.mov").path
            var reported: Int64 = 0
            let moved = try backend.downloadInSegments(
                Self.request(to: destination, on: backend),
                plan: try #require(SegmentedDownloadPlan(totalSize: 5000, segmentSize: 1250)),
                progress: { reported += $0 },
                isCancelled: { false }
            )
            #expect(moved == 5000)
            #expect(reported == 5000)
            #expect(transport.segmentRuns == [[1, 2, 3, 4]])
            #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == contents)
        }
        #expect(Self.everySegmentFileIsGone(transport))
    }

    /// The refusal this route has to survive, and the reason it is not an error: an `sftp`-only
    /// account answers with a sentence on stdout, exit 1 — so the run "succeeds" and every piece is
    /// 43 bytes. Nothing but the length says so.
    @Test("an account with no exec channel is detected by the pieces' length, not by an error")
    func noExecChannelIsCaughtByLength() throws {
        let transport = FakeSFTPTransport()
        transport.fileBytes = Data(repeating: 9, count: 5000)
        transport.hasNoExecChannel = true
        let backend = SFTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let destination = directory.appendingPathComponent("clip.mov").path
            let moved = try backend.downloadInSegments(
                Self.request(to: destination, on: backend),
                plan: try #require(SegmentedDownloadPlan(totalSize: 5000, segmentSize: 1250)),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(moved == nil)
            // Half a file under the real name is worse than no file: the retry writes it properly.
            #expect(!FileManager.default.fileExists(atPath: destination))
        }
        #expect(backend.segmentation.isRefused)
        #expect(Self.everySegmentFileIsGone(transport))
    }

    /// And it is remembered, because the fallback is not free — every file would otherwise pay four
    /// key exchanges to be told the same thing.
    @Test("a refusal is remembered for the life of the connection")
    func aRefusalIsRemembered() throws {
        let transport = FakeSFTPTransport()
        transport.fileBytes = Data(count: Int(17 * Self.mebibyte))
        transport.hasNoExecChannel = true
        let backend = SFTPBackend(location: Self.location, transport: transport)

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
            #expect(transport.segmentRuns.count == 1)
            #expect(transport.downloads.count == 2)
        }
    }

    /// The narrowness control: a file that is not there serves nothing, so it says nothing about
    /// whether this server can split a download. Latching on it would cost every later download its
    /// fast path for one missing name.
    @Test("a failure that served nothing is not evidence about the exec channel")
    func aTotalFailureDoesNotLatch() throws {
        let transport = FakeSFTPTransport()
        transport.error = .notFound
        let backend = SFTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let moved = try backend.downloadInSegments(
                Self.request(to: directory.appendingPathComponent("a").path, on: backend),
                plan: try #require(SegmentedDownloadPlan(totalSize: 5000, segmentSize: 1250)),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(moved == nil) // still falls back — the single stream reports the real reason
        }
        #expect(!backend.segmentation.isRefused)
    }

    @Test("a server that ignores the range falls back, and is remembered")
    func ignoredRangesFallBackAndLatch() throws {
        let transport = FakeSFTPTransport()
        transport.fileBytes = Data(repeating: 3, count: 5000)
        transport.ignoresRanges = true
        let backend = SFTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let moved = try backend.downloadInSegments(
                Self.request(to: directory.appendingPathComponent("a").path, on: backend),
                plan: try #require(SegmentedDownloadPlan(totalSize: 5000, segmentSize: 1250)),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(moved == nil)
        }
        #expect(backend.segmentation.isRefused)
    }

    @Test("a cancellation is not a refusal and is not retried")
    func cancellationIsRethrown() throws {
        let transport = FakeSFTPTransport()
        let backend = SFTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            #expect(throws: CancellationError.self) {
                _ = try backend.downloadInSegments(
                    Self.request(to: directory.appendingPathComponent("a").path, on: backend),
                    plan: try #require(SegmentedDownloadPlan(totalSize: 5000, segmentSize: 1250)),
                    progress: { _ in },
                    isCancelled: { true }
                )
            }
        }
        #expect(!backend.segmentation.isRefused)
    }

    /// The **default** is the code under test here: a transport that cannot split a request
    /// downloads the whole file and says which of the two it did.
    @Test("a transport with no segmented verb downloads the file whole, and says so")
    func defaultForwardsToOneStream() throws {
        let transport = SingleStreamSFTPTransport()
        let outcome = try transport.downloadSegments(
            [DownloadSegment(number: 1, localPath: "/tmp/1", range: 0..<100)],
            of: "/pub/clip.mov",
            to: "/tmp/whole",
            progress: { _ in },
            isCancelled: { false }
        )
        guard case let .whole(bytes) = outcome else {
            Issue.record("expected the whole file, got \(outcome)")
            return
        }
        #expect(bytes == 4321)
        #expect(transport.downloaded == ["/pub/clip.mov"])
    }

    // MARK: - The fork

    @Test("a fresh download of a known, worthwhile size is split")
    func forkSplitsAWorthwhileDownload() throws {
        let transport = FakeSFTPTransport()
        transport.fileBytes = Data(count: Int(17 * Self.mebibyte))
        let backend = SFTPBackend(location: Self.location, transport: transport)

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
        let transport = FakeSFTPTransport()
        transport.fileBytes = Data(count: Int(17 * Self.mebibyte))
        let backend = SFTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            try backend.copyFile(
                at: VFSPath(backend: backend.id, path: "/pub/clip.mov"),
                to: .local(directory.appendingPathComponent("clip.mov").path),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(transport.segmentRuns.isEmpty)
            #expect(transport.downloads.count == 1)
        }
    }

    @Test("a file under SFTP's threshold takes one stream however good the hint is")
    func forkLeavesSmallFilesAlone() throws {
        let transport = FakeSFTPTransport()
        let backend = SFTPBackend(location: Self.location, transport: transport)

        try withDirectory { directory in
            try backend.copyFile(
                at: VFSPath(backend: backend.id, path: "/pub/note.txt"),
                to: .local(directory.appendingPathComponent("note.txt").path),
                // Over S3's threshold and under SFTP's, which is the point of a table per protocol.
                expectedSize: 12 * Self.mebibyte,
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(transport.segmentRuns.isEmpty)
            #expect(transport.downloads.count == 1)
        }
    }

    @Test("a partial already on disk still resumes, in one stream")
    func forkResumesAPartial() throws {
        let transport = FakeSFTPTransport()
        transport.listings["/pub/clip.mov"] = Self.row(bytes: 17 * Self.mebibyte)
        let backend = SFTPBackend(location: Self.location, transport: transport)

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

    // MARK: - Helpers

    private static func row(bytes: Int64) -> String {
        "-rw-r--r--    ? 501      20        \(bytes) Aug 24 12:00 /pub/clip.mov"
    }

    private static func request(to localPath: String, on backend: SFTPBackend)
        -> SFTPDownloadRequest {
        SFTPDownloadRequest(
            remotePath: "/pub/clip.mov",
            localPath: localPath,
            source: VFSPath(backend: backend.id, path: "/pub/clip.mov"),
            expectedSize: nil
        )
    }

    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return -1 }
        return size
    }

    private static func everySegmentFileIsGone(_ transport: FakeSFTPTransport) -> Bool {
        transport.segmentRequests.flatMap { $0 }.allSatisfy { segment in
            let url = URL(fileURLWithPath: segment.localPath)
            return !FileManager.default.fileExists(atPath: segment.localPath)
                && !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-sftpseg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

/// A transport that implements only the single-stream download, so ``SFTPTransport``'s forwarding
/// default is what runs. It cannot be `FakeSFTPTransport` — that one implements the segmented verb,
/// which is exactly what has to be absent here.
private final class SingleStreamSFTPTransport: SFTPTransport, @unchecked Sendable {
    private(set) var downloaded: [String] = []

    func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        downloaded.append(remotePath)
        return 4321
    }

    func listDirectory(_ remotePath: String) throws -> String { "" }

    func createSymbolicLink(_ remotePath: String, target: String) throws {}

    func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        0
    }

    func makeDirectory(_ remotePath: String) throws {}

    func createEmptyFile(_ remotePath: String) throws {}

    func rename(_ source: String, to destination: String) throws {}

    func removeFile(_ remotePath: String) throws {}

    func removeDirectory(_ remotePath: String) throws {}
}
