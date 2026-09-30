import Foundation
import Testing

@testable import DirnexCore

/// What a transfer reports *while* it runs, and what it settles on when it stops.
///
/// Both halves matter and they pull opposite ways. Until 2026-08-14 an S3 copy reported its bytes
/// exactly once, when the invocation exited — measured on the real endpoint as **99 seconds** of a
/// motionless bar for a 29 MB upload, which is what a user reported as the copy not working. What
/// fixed it is an estimate delivered as the bytes move, and an estimate is precisely what must not
/// be allowed to decide the final count: `curl`'s meter has one-per-cent resolution, so a job that
/// simply added the estimates up would end on a number that is nearly right, for a file whose size
/// is known exactly. Every test here holds both: the deltas arrive, **and** they sum to the exact
/// figure the write-out reported.
@Suite("S3 transfer progress")
struct S3TransferProgressTests {
    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "1000genomes",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private func backend(_ transport: FakeS3Transport) -> S3Backend {
        S3Backend(location: location, transport: transport)
    }

    private func path(_ value: String) -> VFSPath { VFSPath(backend: .s3(location), path: value) }
    private func localPath(_ value: String) -> VFSPath { VFSPath(backend: .local, path: value) }

    /// Run one copy and collect every delta it reported, in order.
    private func deltas(
        _ transport: FakeS3Transport,
        from source: VFSPath,
        to destination: VFSPath
    ) throws -> [Int64] {
        var reported: [Int64] = []
        try backend(transport).copyFile(
            at: source,
            to: destination,
            progress: { reported.append($0) },
            isCancelled: { false }
        )
        return reported
    }

    // MARK: - The flag that makes an upload observable at all

    /// An upload's only observable is `curl`'s meter, and `-s` silences it — which is why a 29 MB
    /// upload to the real endpoint reported its bytes once, 99 seconds after it started
    /// (measured 2026-08-14). `-S` keeps the error text that `-sS` was chosen for.
    @Test("the verbs that send bytes let curl's progress meter through; nothing else does")
    func onlyUploadsShowTheProgressMeter() {
        let session = S3Session(location: location)
        let uploads = [
            S3ProcessArguments.upload(session: session, key: "k", localPath: "/tmp/k"),
            S3ProcessArguments.uploadPart(
                session: session,
                key: "k",
                uploadID: "id",
                partNumber: 1,
                localPath: "/tmp/part"
            )
        ]
        for arguments in uploads {
            #expect(arguments.contains("-S"))
            #expect(!arguments.contains("-sS"), "the meter has to reach stderr to be read at all")
        }

        // Everything else stays silent — including the download, which reports progress by watching
        // its own destination file grow and therefore needs no change to these flags at all.
        let quiet = [
            S3ProcessArguments.list(session: session, prefix: ""),
            S3ProcessArguments.head(session: session, key: "k"),
            S3ProcessArguments.download(
                session: session,
                key: "k",
                localPath: "/tmp/k",
                resume: false
            ),
            S3ProcessArguments.putEmptyObject(session: session, key: "docs/"),
            S3ProcessArguments.createMultipartUpload(session: session, key: "k"),
            S3ProcessArguments.completeMultipartUpload(
                session: session,
                key: "k",
                uploadID: "id",
                bodyPath: "/tmp/manifest.xml"
            )
        ]
        for arguments in quiet {
            #expect(arguments.contains("-sS"))
        }
    }

    // MARK: - Upload

    @Test("an upload reports as it goes, and still ends on the exact byte count")
    func uploadStreamsAndReconciles() throws {
        let transport = FakeS3Transport()
        transport.writeResponse = S3Response(status: 200, bytesTransferred: 29_000_000)
        // What a one-per-cent meter yields on a 29 MB file: three sightings, none of them the truth.
        transport.streamedProgress = [7_250_000, 7_250_000, 14_210_000]

        let reported = try deltas(
            transport,
            from: localPath("/tmp/DSC_0002.NEF"),
            to: path("/photos/DSC_0002.NEF")
        )

        #expect(reported.count == 4, "three sightings while it ran, then the remainder")
        #expect(reported.allSatisfy { $0 >= 0 }, "the queue's tally only adds")
        let total = reported.reduce(0, +)
        let exact: Int64 = 29_000_000
        #expect(total == exact)
    }

    @Test("an upload that streamed nothing reports the whole count once, as it always did")
    func uploadWithoutAMeterIsUnchanged() throws {
        let transport = FakeS3Transport()
        transport.writeResponse = S3Response(status: 200, bytesTransferred: 4096)

        let reported = try deltas(
            transport,
            from: localPath("/tmp/report.pdf"),
            to: path("/docs/report.pdf")
        )

        // The endpoint that sends no usable meter (or a file whose size cannot be read) must still
        // report its bytes — the estimate is an addition to this path, never a replacement for it.
        let whole: Int64 = 4096
        #expect(reported == [whole])
    }

    @Test("an estimate that overshoots the exact count never reports a negative delta")
    func overshootIsClamped() throws {
        let transport = FakeS3Transport()
        // A short write: curl says it sent 1000 bytes, having already estimated 1200 on the way.
        transport.writeResponse = S3Response(status: 200, bytesTransferred: 1000)
        transport.streamedProgress = [1200]

        let reported = try deltas(
            transport,
            from: localPath("/tmp/short.bin"),
            to: path("/short.bin")
        )

        #expect(reported.allSatisfy { $0 >= 0 })
        // Nothing subtracts: the overshoot is left standing rather than reported back out, because
        // a queue that has already drawn those bytes cannot un-draw them without the bar going
        // backwards. The reconciliation's job is to never *under*-report the finished file.
        let estimate: Int64 = 1200
        #expect(reported == [estimate])
    }

    // MARK: - Download

    @Test("a download reports as it goes, and still ends on the exact byte count")
    func downloadStreamsAndReconciles() throws {
        let transport = FakeS3Transport()
        transport.downloadResponse = S3Response(status: 200, bytesTransferred: 257_098)
        transport.streamedProgress = [100_000, 100_000]

        let reported = try deltas(
            transport,
            from: path("/README.analysis_history"),
            to: localPath("/tmp/README.analysis_history")
        )

        #expect(reported.count == 3)
        let total = reported.reduce(0, +)
        let exact: Int64 = 257_098
        #expect(total == exact)
    }

    // MARK: - Multipart

    @Test("each part reports within itself and is topped up to the plan's own length")
    func multipartStreamsWithinEachPart() throws {
        let transport = FakeS3Transport()
        let tree = try TempTree()
        defer { tree.cleanup() }
        // Two parts of 5 MiB, the second one short — the plan is the arithmetic under test.
        let partSize: Int64 = 5 * 1024 * 1024
        let totalSize = partSize + 1024
        try tree.writeFile("big.bin", contents: String(repeating: "x", count: Int(totalSize)))
        // Half a part per sighting, so every part streams twice and lands short of its length.
        transport.streamedProgress = [partSize / 2, partSize / 2 - 8]

        let plan = try #require(S3MultipartPlan(totalSize: totalSize, partSize: partSize))
        var reported: [Int64] = []
        let moved = try backend(transport).uploadInParts(
            S3MultipartRequest(
                localPath: tree.path("big.bin"),
                key: "big.bin",
                destination: path("/big.bin"),
                plan: plan
            ),
            progress: { reported.append($0) },
            isCancelled: { false }
        )

        #expect(plan.partCount == 2)
        #expect(reported.allSatisfy { $0 >= 0 })
        let total = reported.reduce(0, +)
        #expect(total == totalSize, "the deltas add up to the file, not to the estimates")
        #expect(moved == totalSize)
    }
}
