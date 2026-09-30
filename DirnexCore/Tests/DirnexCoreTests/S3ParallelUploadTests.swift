import Foundation
import Testing

@testable import DirnexCore

/// Sending a multipart upload's parts **several at a time** (docs/HISTORY.md ▸ After M19).
///
/// One part is one connection, and a loop that sends one 16 MiB part and waits leaves most of a
/// link idle. The parts still have to arrive as themselves, though, and that is what this suite is
/// about: which parts go together, what one `curl` is told to do with them, and how four answers
/// arriving on one stream are told apart.
@Suite("S3 parallel multipart upload")
struct S3ParallelUploadTests {
    private static let location = S3Location(
        host: "s3.eu-north-1.amazonaws.com",
        bucket: "backup",
        region: "eu-north-1",
        accessKeyID: "AKIAEXAMPLE"
    )
    private static let mebibyte: Int64 = 1024 * 1024

    // MARK: - Which parts go together

    @Test("an ordinary upload sends four parts at a time")
    func fourAtATime() throws {
        let plan = try #require(S3MultipartPlan(totalSize: 200 * Self.mebibyte))
        #expect(plan.partSize == 16 * Self.mebibyte)
        #expect(plan.partCount == 13)
        #expect(plan.partsInFlight == 4)
        #expect(plan.batches == [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13]])
    }

    /// The batches are the plan's parts, each exactly once, in order — the property that keeps the
    /// completion manifest able to name what was sent.
    @Test("the batches cover every part once, in order")
    func batchesCoverEveryPart() throws {
        for size in [1, 5, 17, 64, 999] {
            let plan = try #require(S3MultipartPlan(totalSize: Int64(size), partSize: 1))
            #expect(plan.batches.flatMap { $0 } == Array(1...size))
            #expect(plan.batches.allSatisfy { $0.count <= plan.partsInFlight })
        }
    }

    @Test("a two-part file runs two at a time, not four")
    func fewerPartsThanTheCap() throws {
        let plan = try #require(S3MultipartPlan(totalSize: 100 * Self.mebibyte))
        #expect(plan.partCount == 7)
        #expect(plan.batches == [[1, 2, 3, 4], [5, 6, 7]])

        let small = try #require(S3MultipartPlan(totalSize: 2, partSize: 1))
        #expect(small.partsInFlight == 2)
        #expect(small.batches == [[1, 2]])
    }

    /// Every part in flight is a slice cut to a temp file first, so the concurrency is bounded by
    /// **disk** as well as by policy — and it gives way rather than the disk does.
    @Test("a part too large for the staging budget lowers the concurrency")
    func stagingBudgetBounds() throws {
        let huge = try #require(
            S3MultipartPlan(totalSize: 4096 * Self.mebibyte, partSize: 200 * Self.mebibyte)
        )
        #expect(huge.partsInFlight == 2) // 512 MiB budget / 200 MiB parts
        let enormous = try #require(
            S3MultipartPlan(totalSize: 4096 * Self.mebibyte, partSize: 1024 * Self.mebibyte)
        )
        // Never below one: sending a part at a time is what this code did before parallelism, not
        // a state to refuse.
        #expect(enormous.partsInFlight == 1)
        #expect(enormous.batches == [[1], [2], [3], [4]])
    }

    // MARK: - What curl is told

    @Test("the invocation runs the sections in parallel, immediately, with the meter off")
    func invocationFlags() {
        let invocation = Self.invocation(parts: 3)
        #expect(invocation.arguments == [
            "-Z", "--parallel-immediate", "--parallel-max", "3", "-sS", "-K", "-"
        ])
    }

    /// `--parallel-immediate` is the flag whose absence is silent: without it `curl` runs the first
    /// transfer alone before starting the rest, so a batch costs two rounds instead of one and
    /// nothing says so (measured 1.02 s against 0.51 s for four parts).
    @Test("--parallel-immediate is not optional")
    func parallelImmediateIsPresent() {
        #expect(Self.invocation(parts: 4).arguments.contains("--parallel-immediate"))
    }

    @Test("each part is its own section, with its own credential, url and write-out")
    func configurationSections() {
        let configuration = Self.invocation(parts: 2).configuration
        let sections = configuration.components(separatedBy: "next\n")
        #expect(sections.count == 2)
        for (index, section) in sections.enumerated() {
            let number = index + 1
            #expect(section.contains("user = \"AKIAEXAMPLE:s3cr3t\""))
            #expect(section.contains("aws-sigv4 = \"aws:amz:eu-north-1:s3\""))
            #expect(section.contains("connect-timeout = 15"))
            #expect(section.contains("max-time = 3600"))
            #expect(section.contains("upload-file = \"/tmp/slice\(number)\""))
            #expect(section.contains("s3-part\(number)-status="))
        }
    }

    /// The upload id is percent-encoded into the query for the same reason a continuation token is:
    /// it is an opaque server-chosen value, so a `/` or `+` in one would silently address something
    /// else the day a server issues one.
    @Test("the part number and the encoded upload id name the request")
    func partURL() {
        let configuration = Self.invocation(parts: 1).configuration
        #expect(configuration.contains(
            "url = \"https://backup.s3.eu-north-1.amazonaws.com/big.bin?partNumber=1&uploadId=UP%2F1\""
        ))
    }

    /// The security assertion this project makes of every builder: the secret travels on **stdin**
    /// and is nowhere any `ps` could read it.
    @Test("no secret reaches argv")
    func noSecretInArguments() {
        let invocation = Self.invocation(parts: 4)
        #expect(!invocation.arguments.contains { $0.contains("s3cr3t") })
        #expect(invocation.configuration.contains("s3cr3t"))
    }

    // MARK: - Telling four answers apart on one stream

    /// Captured from a real `curl` 8.7.1 run of this exact invocation (2026-08-23) — four sections
    /// against a local endpoint, answering out of order, which is the ordinary case.
    private static let capturedStderr = """

    s3-part4-status=200
    s3-part4-etag="etag-part-4"
    s3-part4-up=8388608

    s3-part1-status=200
    s3-part1-etag="etag-part-1"
    s3-part1-up=8388608

    s3-part2-status=200
    s3-part2-etag="etag-part-2"
    s3-part2-up=8388608

    s3-part3-status=200
    s3-part3-etag="etag-part-3"
    s3-part3-up=8388608

    """

    @Test("every part's answer is read back from the one stream")
    func parsesCapturedBatch() throws {
        let reported = S3PartWriteOut.parse(stderr: Self.capturedStderr)
        #expect(reported.completedParts == [1, 2, 3, 4])
        for number in 1...4 {
            let fields = try #require(reported.fields(forPart: number))
            #expect(fields.status == 200)
            // Quotes included — S3 compares an ETag byte for byte when it assembles the object.
            #expect(fields.etag == "\"etag-part-\(number)\"")
            #expect(fields.bytesUploaded == 8_388_608)
        }
    }

    @Test("a reader fed in arbitrary chunks reads the same thing")
    func parsesChunked() throws {
        var reader = S3PartWriteOut()
        // Split every seven characters, so labels and values are cut mid-token — which is what a
        // pipe that fills mid-write does.
        var remaining = Substring(Self.capturedStderr)
        while !remaining.isEmpty {
            let end = remaining.index(
                remaining.startIndex,
                offsetBy: 7,
                limitedBy: remaining.endIndex
            ) ?? remaining.endIndex
            reader.consume(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        #expect(reader.completedParts == [1, 2, 3, 4])
        #expect(reader.fields(forPart: 2)?.etag == "\"etag-part-2\"")
    }

    /// The progress hook: a part is *done* the moment its status lands, and the caller reports that
    /// part's length then. Nothing else in a batch can say so — several transfers share one meter,
    /// and nothing local grows.
    @Test("a part joins the completed set as its own line lands")
    func completionIsIncremental() {
        var reader = S3PartWriteOut()
        #expect(reader.completedParts.isEmpty)
        reader.consume("\ns3-part2-status=200\ns3-part2-etag=\"e2\"\n")
        #expect(reader.completedParts == [2])
        reader.consume("\ns3-part1-status=200\n")
        #expect(reader.completedParts == [1, 2])
    }

    /// A section `curl` never ran prints nothing at all, and that is not a status of 0: the caller
    /// has to tell "the invocation died before this part" from "this part was refused".
    @Test("a part that never ran reports nothing, where a refused one reports its status")
    func missingPartIsNotAStatus() throws {
        let reported = S3PartWriteOut.parse(stderr: """
        curl: (22) The requested URL returned error: 403

        s3-part1-status=403
        s3-part1-etag=
        s3-part1-up=65536
        """)
        #expect(reported.fields(forPart: 2) == nil)
        let refused = try #require(reported.fields(forPart: 1))
        #expect(refused.status == 403)
        // No ETag at all, rather than an empty one that could be quoted into a manifest.
        #expect(refused.etag == nil)
        #expect(refused.bytesUploaded == 65536)
    }

    @Test("curl's own prose on the same stream is ignored")
    func proseIsIgnored() {
        let reported = S3PartWriteOut.parse(stderr: """
        curl: (6) Could not resolve host: example.invalid
        s3-status=200
        not-a-label
        s3-partX-status=200
        """)
        #expect(reported.completedParts.isEmpty)
    }

    // MARK: - The backend hands over batches

    @Test("the backend uploads in batches of the plan's width")
    func backendBatchesParts() throws {
        let transport = FakeS3Transport()
        transport.writeResponse = S3Response(status: 200, etag: "\"e\"")
        let backend = S3Backend(location: Self.location, transport: transport)
        let plan = try #require(S3MultipartPlan(totalSize: 1000, partSize: 100))

        try withLocalFile(size: 1000) { localPath in
            _ = try backend.uploadInParts(
                S3MultipartRequest(
                    localPath: localPath,
                    key: "big.bin",
                    destination: VFSPath(backend: backend.id, path: "/big.bin"),
                    plan: plan
                ),
                progress: { _ in },
                isCancelled: { false }
            )
        }

        #expect(transport.partBatches == [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10]])
        // Every part still sent, once, in order — a batch changes when they go, not which.
        let numbers = transport.writes.compactMap { write -> Int? in
            if case let .uploadPart(part) = write { return part.partNumber }
            return nil
        }
        #expect(numbers == Array(1...10))
    }

    /// The protocol's **default** is the code under test here, and it is the half that keeps this
    /// change additive: a transport that has not implemented the batch verb sends the parts one at
    /// a time and produces the identical object. That is why this default forwards where the
    /// cross-bucket copy's refuses — sequential is slow, never wrong, while a copy that guessed at
    /// a bucket would be wrong and say nothing.
    @Test("a transport with no batch verb of its own still sends every part, in order")
    func sequentialTransportStillUploads() throws {
        let transport = SingleVerbTransport()
        let parts = (1...3).map {
            S3PartRequest(localPath: "/tmp/s\($0)", key: "k", uploadID: "u", number: $0)
        }
        let responses = try transport.uploadParts(parts, progress: { _ in }, isCancelled: { false })
        #expect(responses.count == 3)
        #expect(transport.uploaded == [1, 2, 3])
    }

    @Test("and it stops when the caller does")
    func sequentialTransportHonoursCancellation() {
        let transport = SingleVerbTransport()
        let parts = (1...3).map {
            S3PartRequest(localPath: "/tmp/s\($0)", key: "k", uploadID: "u", number: $0)
        }
        #expect(throws: CancellationError.self) {
            _ = try transport.uploadParts(
                parts,
                progress: { _ in },
                isCancelled: { transport.uploaded.count >= 1 }
            )
        }
        #expect(transport.uploaded == [1])
    }

    private static func invocation(parts count: Int) -> S3ParallelInvocation {
        S3ProcessArguments.uploadParts(
            session: S3Session(location: location, connectTimeout: 15, maxTime: 3600),
            parts: (1...count).map {
                S3PartRequest(
                    localPath: "/tmp/slice\($0)",
                    key: "big.bin",
                    uploadID: "UP/1",
                    number: $0
                )
            },
            credentials: S3ConfigFile.credentials(
                accessKeyID: "AKIAEXAMPLE",
                secretAccessKey: "s3cr3t"
            )
        )
    }

    private func withLocalFile(size: Int, _ body: (String) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-parallel-\(UUID().uuidString)")
        try Data(repeating: UInt8(ascii: "x"), count: size).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url.path)
    }
}

/// A transport that implements only the single-part verb, so ``S3Transport``'s forwarding default
/// for a batch is what runs. It cannot be `FakeS3Transport` — that one implements the batch verb,
/// which is exactly what has to be absent here.
private final class SingleVerbTransport: S3Transport, @unchecked Sendable {
    private(set) var uploaded: [Int] = []

    func uploadPart(
        _ part: S3PartRequest,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        uploaded.append(part.number)
        return S3Response(status: 200, etag: "\"e\(part.number)\"")
    }

    func listObjects(
        prefix: String,
        delimiter: String?,
        continuationToken: String?
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func download(
        key: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func head(key: String) throws -> S3Response { S3Response(status: 200) }

    func upload(
        localPath: String,
        to key: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func putEmptyObject(key: String) throws -> S3Response { S3Response(status: 200) }

    func copyObject(from sourceKey: String, to destinationKey: String) throws -> S3Response {
        S3Response(status: 200)
    }

    func deleteObject(key: String) throws -> S3Response { S3Response(status: 200) }

    func deleteObjects(keys: [String]) throws -> S3Response { S3Response(status: 200) }

    func createMultipartUpload(key: String) throws -> S3Response { S3Response(status: 200) }

    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart]
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func abortMultipartUpload(key: String, uploadID: String) throws -> S3Response {
        S3Response(status: 200)
    }
}
