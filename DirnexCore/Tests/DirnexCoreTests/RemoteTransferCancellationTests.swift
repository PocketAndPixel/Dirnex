import Foundation
import Testing

@testable import DirnexCore

/// That Stop reaches **inside** a remote transfer, for all three remote backends at once
/// (PLAN.md §M21 Slice 10).
///
/// One suite rather than a test in each backend's own file, because the bug it guards was one rule
/// with three spellings: `S3Backend`, `FTPBackend` and `SFTPBackend` each checked `isCancelled()`
/// before and after the transfer and handed the byte-moving to a transport that never saw the flag,
/// so pressing Stop did nothing until there was nothing left to cancel. Measured 2026-08-14 through
/// the real S3 backend and the app's own transport: Stop at 1.00 s, `copyFile` back at **16.98 s**,
/// the whole 4 MiB downloaded and then discarded (docs/NOTES.md ▸ curl for S3). Splitting these
/// across three files is how the next backend gets added without one.
///
/// **What a headless test can and cannot say.** It cannot reproduce the measurement — that needs a
/// real process and a slow server, and it is why the probe exists. What it pins is the half the
/// compiler will not: that each backend *hands the flag down to the transfer verb*, rather than
/// consulting it only at the file boundary. The flag here answers `false` once and `true` after,
/// so the `copyFile` entry check passes and only a transport that is genuinely asked can report it.
///
/// **The `throws` assertion is not the evidence, and believing it would be the whole bug again.**
/// Running the negative control — one backend reverted to passing `{ false }` down — every
/// `#expect(throws: CancellationError.self)` still passed, because the *post*-transfer boundary
/// check throws whether or not anything was actually stopped. That is precisely the shape the
/// shipped code had: an operation that reports "cancelled" having done all of the work. Only
/// `cancelledTransfers` separates the two, so it is the assertion that carries every test here.
@Suite("Remote transfer cancellation")
struct RemoteTransferCancellationTests {
    /// A Stop that arrives *after* the operation has begun.
    ///
    /// `copyFile` asks once on entry, before anything has been spawned; answering `true` there
    /// short-circuits into the pre-existing boundary check and would make every assertion below
    /// pass without the flag ever reaching a transport — the test passing for the wrong reason,
    /// which is the shape this whole slice keeps finding.
    private final class StopAfterFirstAsk: @unchecked Sendable {
        private var asks = 0
        func callAsFunction() -> Bool {
            asks += 1
            return asks > 1
        }
    }

    private func temporaryPath() -> String {
        "\(NSTemporaryDirectory())dirnex-cancel-\(UUID().uuidString)"
    }

    // MARK: - S3

    @Test("S3 hands cancellation down to the download")
    func s3DownloadIsCancellable() throws {
        let location = S3Location(
            host: "s3.us-east-1.amazonaws.com",
            bucket: "1000genomes",
            region: "us-east-1",
            accessKeyID: "AKIAEXAMPLE"
        )
        let transport = FakeS3Transport()
        transport.downloadResponse = S3Response(status: 200, bytesTransferred: 10)
        let sut = S3Backend(location: location, transport: transport)
        let stop = StopAfterFirstAsk()

        #expect(throws: CancellationError.self) {
            try sut.copyFile(
                at: VFSPath(backend: .s3(location), path: "/data/big.bam"),
                to: .local(temporaryPath()),
                progress: { _ in },
                isCancelled: { stop() }
            )
        }
        #expect(transport.cancelledTransfers == ["data/big.bam"])
    }

    @Test("S3 hands cancellation down to the upload")
    func s3UploadIsCancellable() throws {
        let location = S3Location(
            host: "s3.us-east-1.amazonaws.com",
            bucket: "1000genomes",
            region: "us-east-1",
            accessKeyID: "AKIAEXAMPLE"
        )
        let transport = FakeS3Transport()
        let source = temporaryPath()
        try "payload".write(toFile: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: source) }
        let sut = S3Backend(location: location, transport: transport)
        let stop = StopAfterFirstAsk()

        #expect(throws: CancellationError.self) {
            try sut.copyFile(
                at: .local(source),
                to: VFSPath(backend: .s3(location), path: "/data/out.bin"),
                progress: { _ in },
                isCancelled: { stop() }
            )
        }
        #expect(transport.cancelledTransfers == ["data/out.bin"])
    }

    // MARK: - FTP

    @Test("FTP hands cancellation down to the download")
    func ftpDownloadIsCancellable() throws {
        let location = FTPLocation(host: "nas.local", port: 21, username: "sa")
        let transport = FakeFTPTransport()
        let sut = FTPBackend(location: location, transport: transport)
        let stop = StopAfterFirstAsk()

        #expect(throws: CancellationError.self) {
            try sut.copyFile(
                at: VFSPath(backend: .ftp(location), path: "/pub/big.iso"),
                to: .local(temporaryPath()),
                progress: { _ in },
                isCancelled: { stop() }
            )
        }
        #expect(transport.cancelledTransfers == ["/pub/big.iso"])
    }

    @Test("FTP hands cancellation down to the upload")
    func ftpUploadIsCancellable() throws {
        let location = FTPLocation(host: "nas.local", port: 21, username: "sa")
        let transport = FakeFTPTransport()
        let source = temporaryPath()
        try "payload".write(toFile: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: source) }
        let sut = FTPBackend(location: location, transport: transport)
        let stop = StopAfterFirstAsk()

        #expect(throws: CancellationError.self) {
            try sut.copyFile(
                at: .local(source),
                to: VFSPath(backend: .ftp(location), path: "/pub/out.bin"),
                progress: { _ in },
                isCancelled: { stop() }
            )
        }
        #expect(transport.cancelledTransfers == ["/pub/out.bin"])
    }

    // MARK: - SFTP

    @Test("SFTP hands cancellation down to the download")
    func sftpDownloadIsCancellable() throws {
        let location = SFTPLocation(host: "example.com", port: 22, username: "oleg")
        let transport = FakeSFTPTransport()
        let sut = SFTPBackend(location: location, transport: transport)
        let stop = StopAfterFirstAsk()

        #expect(throws: CancellationError.self) {
            try sut.copyFile(
                at: VFSPath(backend: .sftp(location), path: "/home/oleg/big.tar"),
                to: .local(temporaryPath()),
                progress: { _ in },
                isCancelled: { stop() }
            )
        }
        #expect(transport.cancelledTransfers == ["/home/oleg/big.tar"])
    }

    @Test("SFTP hands cancellation down to the upload")
    func sftpUploadIsCancellable() throws {
        let location = SFTPLocation(host: "example.com", port: 22, username: "oleg")
        let transport = FakeSFTPTransport()
        let source = temporaryPath()
        try "payload".write(toFile: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: source) }
        let sut = SFTPBackend(location: location, transport: transport)
        let stop = StopAfterFirstAsk()

        #expect(throws: CancellationError.self) {
            try sut.copyFile(
                at: .local(source),
                to: VFSPath(backend: .sftp(location), path: "/home/oleg/out.bin"),
                progress: { _ in },
                isCancelled: { stop() }
            )
        }
        #expect(transport.cancelledTransfers == ["/home/oleg/out.bin"])
    }

    // MARK: - The other half of the rule

    /// A transfer nobody stopped must still run. Without this the suite above is satisfied by a
    /// backend that cancels *everything*, which is the cheapest possible way to make it green.
    @Test("an uncancelled transfer is not disturbed")
    func uncancelledTransferRuns() throws {
        let location = S3Location(
            host: "s3.us-east-1.amazonaws.com",
            bucket: "1000genomes",
            region: "us-east-1",
            accessKeyID: "AKIAEXAMPLE"
        )
        let transport = FakeS3Transport()
        transport.downloadResponse = S3Response(status: 200, bytesTransferred: 4096)
        let sut = S3Backend(location: location, transport: transport)
        var reported: Int64 = 0

        try sut.copyFile(
            at: VFSPath(backend: .s3(location), path: "/data/small.txt"),
            to: .local(temporaryPath()),
            progress: { reported = $0 },
            isCancelled: { false }
        )

        #expect(transport.cancelledTransfers.isEmpty)
        #expect(reported == 4096)
    }
}
