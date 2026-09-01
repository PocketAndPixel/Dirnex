import Foundation
import Testing

@testable import DirnexCore

/// The fixture both segmented-upload suites are built on.
///
/// Its own type rather than a static on either suite, because the two are split only to stay under
/// SwiftLint's `type_body_length` and must not drift apart: a limits table or a transport that
/// differed between them would make one suite's control silently inapplicable to the other.
enum SegmentedUploadFixture {
    static let location = SFTPLocation(host: "ssh.example", username: "u")

    /// Small enough that a test writes real files in milliseconds, and shaped like the shipped
    /// table: split above 400 bytes, parts of 100–200, four at once.
    static let limits = SegmentedUploadLimits(
        threshold: 400,
        minimumPartSize: 100,
        preferredPartSize: 200,
        maximumPartsInFlight: 4,
        stagingBudget: 4096,
        maximumParts: 10_000
    )

    /// Sized against the shipped ``SFTPBackend/resumeUploadThreshold`` rather than the tiny limits
    /// above: a remote `stat` is only worth a round trip over 1 MiB, so a 1000-byte fixture cannot
    /// reach the resume decision at all and would measure the fork's second condition while claiming
    /// to measure its first.
    static let megabyteLimits = SegmentedUploadLimits(
        threshold: 1 << 20,
        minimumPartSize: 256 * 1024,
        preferredPartSize: 512 * 1024,
        maximumPartsInFlight: 4,
        stagingBudget: 8 << 20,
        maximumParts: 10_000
    )

    /// An account that has an exec channel and answers as a shell would — the state a healthy
    /// OpenSSH server is in, and the one every other fixture here varies from.
    static func readyTransport() -> FakeSFTPTransport {
        let transport = FakeSFTPTransport()
        transport.actsAsShell = true
        transport.uploadBytes = 1000
        return transport
    }

    static func backend(
        _ transport: FakeSFTPTransport,
        limits: SegmentedUploadLimits = limits
    ) -> SFTPBackend {
        var backend = SFTPBackend(location: location, transport: transport)
        backend.segmentedUploadLimits = limits
        return backend
    }

    static func destination(on backend: SFTPBackend) -> VFSPath {
        VFSPath(backend: backend.id, path: "/srv/disk.img")
    }

    static func everyPartFileIsGone(_ transport: FakeSFTPTransport) -> Bool {
        transport.partBatches.flatMap { $0 }
            .allSatisfy { !FileManager.default.fileExists(atPath: $0.localPath) }
    }

    static func withFile(_ contents: Data, _ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-sftpup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("disk.img").path
        try contents.write(to: URL(fileURLWithPath: path))
        try body(path)
    }
}

/// What a segmented SFTP upload leaves on the server, and what it costs on the way
/// (PLAN.md §4 ▸ *Still open*, "No multipart upload over SFTP or FTP").
///
/// The route's own rules, each with a test whose failure would otherwise be silent: the parts are
/// joined **in order** (`cat` splices what it is given), the scratch is **one batch** however large
/// the file is, and the destination is created by `cat` rather than by a transfer verb — so `put -p`
/// carries nothing and the loss is reported rather than assumed away.
@Suite("SFTP segmented upload: the route")
struct SFTPSegmentedUploadRouteTests {
    @Test("a split upload lands the file byte for byte and sweeps its parts away")
    func theServerEndsUpWithTheFile() throws {
        let contents = Data((0..<1000).map { UInt8($0 % 251) })
        let transport = SegmentedUploadFixture.readyTransport()
        let backend = SegmentedUploadFixture.backend(transport)

        try SegmentedUploadFixture.withFile(contents) { localPath in
            var reported: Int64 = 0
            let moved = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { reported += $0 },
                isCancelled: { false }
            )
            #expect(moved == 1000)
            #expect(reported == 1000)
            #expect(transport.partRuns == [[1, 2, 3, 4], [5]])
            #expect(transport.remoteFiles["/srv/disk.img"] == contents)
            // Nothing of this run is left on the server: no parts, no staging file.
            #expect(transport.remoteFiles.keys.filter { $0 != "/srv/disk.img" }.isEmpty)
        }
    }

    @Test("the parts are cut and removed one batch at a time, so the scratch is bounded")
    func scratchIsBoundedByTheBatch() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        let backend = SegmentedUploadFixture.backend(transport)
        // Reads the slices as they are handed over, then asserts on what was on disk at that moment.
        var liveSlices: [Int] = []
        transport.beforeUploadingParts = { parts in
            liveSlices.append(parts.filter { FileManager.default.fileExists(atPath: $0.localPath) }
                .count)
        }

        try SegmentedUploadFixture.withFile(Data(repeating: 7, count: 1000)) { localPath in
            _ = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        // Four in the first batch and one in the second — never all five, which is what "one batch
        // of scratch, whatever the file's size" means.
        #expect(liveSlices == [4, 1])
        #expect(SegmentedUploadFixture.everyPartFileIsGone(transport))
    }

    @Test("progress reports each part as it lands, where one stream can only report at the end")
    func progressMovesPerPart() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        let backend = SegmentedUploadFixture.backend(transport)
        var deltas: [Int64] = []

        try SegmentedUploadFixture.withFile(Data(repeating: 3, count: 1000)) { localPath in
            _ = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { deltas.append($0) },
                isCancelled: { false }
            )
        }
        // Five reports rather than one: the second thing splitting buys, and the one a user sees,
        // since `sftp` gives a single-stream upload no observable at all.
        #expect(deltas == [200, 200, 200, 200, 200])
    }
}
