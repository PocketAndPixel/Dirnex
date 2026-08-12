import Foundation
import Testing

@testable import DirnexCore

/// What has to happen when a multipart upload goes wrong — which is mostly one thing, the abort.
///
/// S3 stores the parts of an unfinished upload and **bills for them**, and they are invisible to an
/// ordinary listing, so an upload that dies without aborting leaves the user paying for bytes they
/// cannot see and did not keep. Every one of these tests asserts the abort ran, because the failure
/// they each provoke is a different way of reaching the same obligation.
@Suite("S3 multipart failures")
struct S3MultipartFailureTests {
    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "1000genomes",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private func destination(_ path: String) -> VFSPath {
        VFSPath(backend: .s3(location), path: path)
    }

    private func withLocalFile(size: Int, _ body: (String) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-upload-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((0..<size).map { UInt8($0 % 256) }).write(to: url)
        try body(url.path)
    }

    /// The request the orchestration tests drive. The part size is *stated* rather than derived so a
    /// whole multi-part upload can be exercised over a few kilobytes: the orchestration is
    /// size-agnostic, and the policy that picks a real part size is pinned separately in
    /// `S3MultipartPlanTests`.
    private func smallRequest(localPath: String, totalSize: Int64) throws -> S3MultipartRequest {
        S3MultipartRequest(
            localPath: localPath,
            key: "big.bin",
            destination: destination("/big.bin"),
            plan: try #require(S3MultipartPlan(totalSize: totalSize, partSize: 400))
        )
    }

    // MARK: - Failure, and the abort that has to follow it

    @Test("a refused part aborts the upload and never completes it")
    func refusedPartAborts() throws {
        let transport = FakeS3Transport()
        transport.uploadPartResponses = [
            S3Response(status: 200, etag: "\"etag-part-1\""),
            S3Response(status: 403, body: Data(S3Fixtures.invalidAccessKey.utf8))
        ]
        let backend = S3Backend(location: location, transport: transport)

        try withLocalFile(size: 1000) { localPath in
            #expect(throws: VFSError.self) {
                _ = try backend.uploadInParts(
                    try smallRequest(localPath: localPath, totalSize: 1000),
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
        }
        #expect(aborted(transport))
        #expect(!completed(transport))
    }

    @Test("a part with no ETag fails before the completion rather than during it")
    func partWithoutETagAborts() throws {
        let transport = FakeS3Transport()
        transport.uploadPartResponses = [S3Response(status: 200, etag: nil)]
        let backend = S3Backend(location: location, transport: transport)

        try withLocalFile(size: 1000) { localPath in
            #expect(throws: VFSError.self) {
                _ = try backend.uploadInParts(
                    try smallRequest(localPath: localPath, totalSize: 1000),
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
        }
        // A part that cannot be named in the manifest can never be completed, so failing at the
        // completion would only make the error further from its cause.
        #expect(aborted(transport))
        #expect(!completed(transport))
    }

    @Test("a completion that failed inside a 200 is a failure, and aborts")
    func completionFailureAborts() throws {
        let transport = FakeS3Transport()
        transport.completeMultipartResponse = .ok(S3Fixtures.completeMultipartFailed)
        let backend = S3Backend(location: location, transport: transport)

        try withLocalFile(size: 1000) { localPath in
            #expect(throws: VFSError.self) {
                _ = try backend.uploadInParts(
                    try smallRequest(localPath: localPath, totalSize: 1000),
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
        }
        #expect(aborted(transport))
    }

    @Test("an opening with no upload id fails without sending anything")
    func missingUploadIDFailsEarly() throws {
        let transport = FakeS3Transport()
        transport.createMultipartResponse = .ok("<Whatever/>")
        let backend = S3Backend(location: location, transport: transport)

        try withLocalFile(size: 1000) { localPath in
            #expect(throws: VFSError.self) {
                _ = try backend.uploadInParts(
                    try smallRequest(localPath: localPath, totalSize: 1000),
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
        }
        // Nothing to abort *with*, so nothing may be sent: an id-less upload that pressed on would
        // create parts nothing could ever clean up.
        let sentParts = transport.writes.contains {
            if case .uploadPart = $0 { return true }
            return false
        }
        #expect(!sentParts)
        #expect(!aborted(transport))
    }

    @Test("cancelling mid-upload aborts and stops sending parts")
    func cancellationAborts() throws {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: location, transport: transport)
        var partsSeen = 0

        try withLocalFile(size: 1000) { localPath in
            #expect(throws: CancellationError.self) {
                _ = try backend.uploadInParts(
                    try smallRequest(localPath: localPath, totalSize: 1000),
                    progress: { _ in partsSeen += 1 },
                    isCancelled: { partsSeen >= 1 }
                )
            }
        }
        #expect(partsSeen == 1)
        #expect(aborted(transport))
        #expect(!completed(transport))
    }

    @Test("an abort that itself fails does not replace the error that caused it")
    func failingAbortKeepsTheOriginalError() throws {
        let transport = FakeS3Transport()
        transport.abortThrows = true
        transport.completeMultipartResponse = .ok(S3Fixtures.completeMultipartFailed)
        let backend = S3Backend(location: location, transport: transport)

        try withLocalFile(size: 1000) { localPath in
            // The completion's failure, not the abort's — the user needs to know why the upload
            // failed, not that the cleanup after it also did.
            #expect(throws: VFSError.self) {
                _ = try backend.uploadInParts(
                    try smallRequest(localPath: localPath, totalSize: 1000),
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
        }
        #expect(aborted(transport))
    }

    // MARK: - Helpers

    private func aborted(_ transport: FakeS3Transport) -> Bool {
        transport.writes.contains {
            if case .abortMultipart = $0 { return true }
            return false
        }
    }

    private func completed(_ transport: FakeS3Transport) -> Bool {
        transport.writes.contains {
            if case .completeMultipart = $0 { return true }
            return false
        }
    }
}
