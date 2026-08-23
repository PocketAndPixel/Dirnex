import Foundation
import Testing

@testable import DirnexCore

/// What becomes of a segmented FTP download's pieces (docs/HISTORY.md ▸ After M19).
///
/// Joining them, the fork that decides whether any of it happens, and — the half that has no S3
/// equivalent — what to do when a server will not serve them all. A connection cap is the commonest
/// way this fails, it is invisible to the user, and no message would help them, so it is not
/// reported: the caller goes back to one stream, and the connection remembers.
@Suite("FTP segmented download: the pieces")
struct FTPSegmentedDownloadBackendTests {
    private static let location = FTPLocation(host: "ftp.example", username: "u")
    private static let mebibyte: Int64 = 1024 * 1024

    // MARK: - The backend

    @Test("a segmented download lands the file byte for byte, and cleans up after itself")
    func backendAssemblesTheFile() throws {
        let contents = Data((0..<5000).map { UInt8($0 % 253) })
        let transport = FakeFTPTransport()
        transport.fileBytes = contents
        let backend = FTPBackend(location: Self.location, transport: transport)

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

    /// The failure this exists to survive. A capped server serves what fits and refuses the rest, so
    /// the run fails as a whole — and no error message would help a user with somebody else's
    /// connection limit, so it is not reported: the caller is sent back to one stream.
    @Test("a server that will not serve them all sends the caller back to one stream")
    func aCappedServerFallsBack() throws {
        let transport = FakeFTPTransport()
        transport.fileBytes = Data(repeating: 9, count: 5000)
        transport.servesAtMostSegments = 1
        let backend = FTPBackend(location: Self.location, transport: transport)

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
        #expect(Self.everySegmentFileIsGone(transport))
    }

    /// And it is remembered, because the fallback is not free: the pieces that *did* arrive were
    /// downloaded in full and thrown away, and without this that price is paid again for every file.
    @Test("a refusal is remembered for the life of the connection")
    func aRefusalIsRemembered() throws {
        let transport = FakeFTPTransport()
        transport.fileBytes = Data(repeating: 9, count: 5000)
        transport.servesAtMostSegments = 1
        let backend = FTPBackend(location: Self.location, transport: transport)
        #expect(!backend.segmentation.isRefused)

        try withDirectory { directory in
            _ = try backend.downloadInSegments(
                Self.request(to: directory.appendingPathComponent("a").path, on: backend),
                plan: try #require(SegmentedDownloadPlan(totalSize: 5000, segmentSize: 1250)),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(backend.segmentation.isRefused)
    }

    /// The narrowness control, and the reason the rule is "the server served us something and the
    /// run still failed" rather than "the run failed": a file that is not there serves nothing, and
    /// latching on that would cost every later download its fast path for one missing name.
    @Test("a failure that served nothing is not evidence about segmentation")
    func aTotalFailureDoesNotLatch() throws {
        let transport = FakeFTPTransport()
        transport.error = .notFound
        let backend = FTPBackend(location: Self.location, transport: transport)

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

    /// A server that ignores `REST` sends the whole file to every section, so every piece is the
    /// wrong length. Assembly refuses it, the caller falls back — and this one *does* latch, since
    /// the server plainly served data and plainly cannot do this.
    @Test("a server that ignores ranges falls back, and is remembered")
    func ignoredRangesFallBackAndLatch() throws {
        let transport = FakeFTPTransport()
        transport.fileBytes = Data(repeating: 3, count: 5000)
        transport.ignoresRanges = true
        let backend = FTPBackend(location: Self.location, transport: transport)

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

    /// Stopping is the user's decision, and retrying what somebody just stopped is the one fallback
    /// that is never wanted.
    @Test("a cancellation is not a refusal and is not retried")
    func cancellationIsRethrown() throws {
        let transport = FakeFTPTransport()
        let backend = FTPBackend(location: Self.location, transport: transport)

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

    /// The **default** is the code under test here, and it is what keeps the transport change
    /// additive: a transport that cannot split a request downloads the whole file and says which of
    /// the two it did.
    @Test("a transport with no segmented verb downloads the file whole, and says so")
    func defaultForwardsToOneStream() throws {
        let transport = SingleStreamFTPTransport()
        let outcome = try transport.downloadSegments(
            Self.segments(2),
            of: "/pub/clip.mov",
            to: "/tmp/whole",
            progress: { _ in },
            isCancelled: { false }
        )
        guard case let .whole(bytes) = outcome else {
            Issue.record("expected the whole file, got \(outcome)")
            return
        }
        #expect(bytes == 1234)
        #expect(transport.downloaded == ["/pub/clip.mov"])
    }

    // MARK: - Helpers

    private static func segments(_ count: Int) -> [DownloadSegment] {
        (1...count).map {
            DownloadSegment(
                number: $0,
                localPath: "/tmp/seg\($0)",
                range: Int64($0 - 1) * 100..<Int64($0) * 100
            )
        }
    }

    private static func request(to localPath: String, on backend: FTPBackend) -> FTPDownloadRequest {
        FTPDownloadRequest(
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

    /// Nothing is left behind — asked of the very files this download was given, and of the
    /// directory holding them, rather than by scanning a temp root shared with every other test in
    /// the process (which is a race, not an assertion).
    private static func everySegmentFileIsGone(_ transport: FakeFTPTransport) -> Bool {
        transport.segmentRequests.flatMap { $0 }.allSatisfy { segment in
            let url = URL(fileURLWithPath: segment.localPath)
            return !FileManager.default.fileExists(atPath: segment.localPath)
                && !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-ftpseg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

/// A transport that implements only the single-stream download, so ``FTPTransport``'s forwarding
/// default is what runs. It cannot be `FakeFTPTransport` — that one implements the segmented verb,
/// which is exactly what has to be absent here.
private final class SingleStreamFTPTransport: FTPTransport, @unchecked Sendable {
    private(set) var downloaded: [String] = []

    func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        downloaded.append(remotePath)
        return 1234
    }

    func listDirectory(_ remotePath: String) throws -> String { "" }

    func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        0
    }

    func fileSize(_ remotePath: String) throws -> Int64 { 0 }

    func fetchCertificate() throws -> FTPCertificate { throw FTPTransportError.notFound }

    func makeDirectory(_ remotePath: String) throws {}

    func createEmptyFile(_ remotePath: String) throws {}

    func rename(_ source: String, to destination: String) throws {}

    func removeFile(_ remotePath: String) throws {}

    func removeDirectory(_ remotePath: String) throws {}
}
