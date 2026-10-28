import Foundation
import Testing

@testable import DirnexCore

/// Real `curl` stderr from S3 transfers under `Fixtures/S3`, named for the exit code each run ended
/// with: `curl-exit28-get-cut` exited 28.
///
/// Captured 2026-10-23 with `curl` 8.7.1 through the shipped argument builders, against
/// `Tooling/fake-s3-endpoint.py` (`CUT_AFTER=100000` for the dropped connection). That endpoint
/// verifies no signature, which does not matter here: the exit code and the write-out are both
/// `curl`'s own. A cut is `--limit-rate 500k` under a one-second `max-time`, given to one section
/// only in a parallel run, and the unwritable destination is a folder with mode 555.
enum S3CurlFixtures {
    static func text(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "stderr",
                subdirectory: "Fixtures/S3"
            )
        )
        return try #require(String(data: Data(contentsOf: url), encoding: .utf8))
    }

    /// One fixture read the way the runner reads a single-transfer run.
    static func run(
        _ name: String,
        measuring direction: S3WriteOut.Direction = .download
    ) throws -> S3Response {
        try S3WriteOut.response(
            exitCode: exitCode(of: name),
            standardOutput: Data(),
            standardError: text(name),
            measuring: direction
        )
    }

    static func exitCode(of name: String) throws -> Int32 {
        let code = try #require(
            name.split(separator: "-").dropFirst().first?.dropFirst("exit".count)
        )
        return try #require(Int32(code))
    }
}

/// A transfer that answered and then stopped is a failure, not a finished copy.
///
/// Each failing case first reads the status the write-out reported, which is what the old
/// status-only rule went on, so the test shows what that rule would have called a success.
@Suite("S3WriteOut: a transfer cut short")
struct S3CutTransferTests {
    // MARK: - One transfer

    @Test("the rule: exit 0, or --fail's 22 with a refusal, and never status 0")
    func rule() {
        let answers: [(status: Int, exit: Int32)] = [
            (200, 0), (206, 0), (404, 0), (416, 0), (404, 22), (503, 22)
        ]
        let stopped: [(status: Int, exit: Int32)] = [
            (200, 22), (301, 22), (200, 28), (200, 18), (200, 23), (100, 28), (206, 56),
            (0, 0), (0, 6), (0, 28)
        ]
        for item in answers {
            #expect(
                S3WriteOut.isAnswer(status: item.status, exitCode: item.exit),
                "status \(item.status), exit \(item.exit)"
            )
        }
        for item in stopped {
            #expect(
                !S3WriteOut.isAnswer(status: item.status, exitCode: item.exit),
                "status \(item.status), exit \(item.exit)"
            )
        }
    }

    @Test("a finished download is a response carrying its byte count")
    func finishedDownload() throws {
        let response = try S3CurlFixtures.run("curl-exit0-get-200")
        #expect(response.isSuccess)
        #expect(response.bytesTransferred == 3_129_010)
        #expect(response.contentLength == 3_129_010)
    }

    @Test("--fail's exit 22 is a refusal the server sent, so a response")
    func failExitIsAResponse() throws {
        let response = try S3CurlFixtures.run("curl-exit22-get-404")
        #expect(response.status == 404)
        #expect(!response.isSuccess)
    }

    /// The report: a 200 and a sixth of the file on disk under the object's name.
    @Test("a download cut short by the time budget is a transport failure, not a 200")
    func cutShortIsNotSuccess() throws {
        let fields = try S3WriteOut.parse(stderr: S3CurlFixtures.text("curl-exit28-get-cut"))
        #expect(fields.status == 200)
        #expect(fields.bytesDownloaded == 528_332)
        #expect(fields.contentLength == 3_129_010)
        #expect(throws: S3ResponseError.transport(.operationTimedOut)) {
            try S3CurlFixtures.run("curl-exit28-get-cut")
        }
    }

    @Test("a connection closed mid-body is a transport failure, not a 200")
    func droppedConnection() throws {
        let fields = try S3WriteOut.parse(stderr: S3CurlFixtures.text("curl-exit18-get-dropped"))
        #expect(fields.status == 200)
        #expect(fields.bytesDownloaded == 100_000)
        #expect(throws: S3ResponseError.transport(.other)) {
            try S3CurlFixtures.run("curl-exit18-get-dropped")
        }
    }

    /// No file was created at all, and the server's answer was a 200.
    @Test("a destination curl cannot write is a failure, though the server said 200")
    func unwritableDestination() throws {
        let fields = try S3WriteOut.parse(stderr: S3CurlFixtures.text("curl-exit23-get-unwritable"))
        #expect(fields.status == 200)
        #expect(fields.bytesDownloaded == 0)
        #expect(throws: S3ResponseError.transport(.other)) {
            try S3CurlFixtures.run("curl-exit23-get-unwritable")
        }
    }

    /// An upload has no 200 to show when it is cut. The only status it has seen is the
    /// `100 Continue` that let the body go, which the status-only rule read as a refusal.
    @Test("an upload cut short is the timeout it was, not a refusal with status 100")
    func uploadCutShort() throws {
        let stderr = try S3CurlFixtures.text("curl-exit28-put-cut")
        #expect(stderr.contains("\r"), "the upload's progress meter shares the stream")
        let fields = S3WriteOut.parse(stderr: stderr)
        #expect(fields.status == 100)
        #expect(fields.bytesUploaded == 524_288)
        #expect(throws: S3ResponseError.transport(.operationTimedOut)) {
            try S3CurlFixtures.run("curl-exit28-put-cut", measuring: .upload)
        }
    }

    /// The inverse half, which the whole backend rests on: S3 refuses with exit 0.
    @Test("a refusal with exit 0 is a response, and the body and counter ride with it")
    func exitZeroRefusal() throws {
        let body = Data("<Error><Code>AccessDenied</Code></Error>".utf8)
        let response = try S3WriteOut.response(
            exitCode: 0,
            standardOutput: body,
            standardError: S3Fixtures.refusedUploadStderr,
            measuring: .upload
        )
        #expect(response.status == 403)
        #expect(response.body == body)
        #expect(response.bytesTransferred == 3_145_728)
    }

    @Test("no answer at all is still classified by the exit code")
    func noAnswer() {
        #expect(throws: S3ResponseError.transport(.couldNotResolveHost)) {
            try S3WriteOut.response(
                exitCode: 6,
                standardOutput: Data(),
                standardError: S3Fixtures.failureStderr
            )
        }
    }

    // MARK: - Several transfers in one run

    /// Both segments report 206, so by status both finished; only their own exit codes differ.
    @Test("a parallel download is read per segment, by each segment's own exit code")
    func segmentCutShort() throws {
        let reported = try S3SegmentWriteOut.parse(
            stderr: S3CurlFixtures.text("curl-exit28-segments-cut")
        )
        #expect(reported.fields(forSegment: 2)?.status == 206)
        #expect(reported.fields(forSegment: 2)?.bytesDownloaded == 544_664)
        let finished = try reported.response(forSegment: 1, processExitCode: 28)
        #expect(finished.status == 206)
        #expect(finished.bytesTransferred == 1_564_505)
        #expect(throws: S3ResponseError.transport(.operationTimedOut)) {
            try reported.response(forSegment: 2, processExitCode: 28)
        }
    }

    @Test("a parallel upload is read per part, and a cut part is a timeout")
    func partCutShort() throws {
        let reported = try S3PartWriteOut.parse(stderr: S3CurlFixtures.text("curl-exit28-parts-cut"))
        #expect(reported.completedParts == [1, 2])
        #expect(reported.fields(forPart: 2)?.status == 100)
        let finished = try reported.response(forPart: 1, processExitCode: 28, body: Data())
        #expect(finished.etag == "\"etag-part-1\"")
        #expect(finished.bytesTransferred == 1_564_505)
        #expect(throws: S3ResponseError.transport(.operationTimedOut)) {
            try reported.response(forPart: 2, processExitCode: 28, body: Data())
        }
    }

    @Test("a section that printed no exit code of its own is read by the process's")
    func sectionWithoutExitCode() throws {
        let reported = S3SegmentWriteOut.parse(stderr: "\ns3-seg1-status=206\ns3-seg1-down=4\n")
        #expect(try reported.response(forSegment: 1, processExitCode: 0).status == 206)
        #expect(throws: S3ResponseError.transport(.operationTimedOut)) {
            try reported.response(forSegment: 1, processExitCode: 28)
        }
    }

    @Test("a section that never ran is classified by the process's exit code")
    func sectionNeverRan() {
        let reported = S3PartWriteOut.parse(stderr: "curl: (7) Failed to connect\n")
        #expect(throws: S3ResponseError.transport(.couldNotConnect)) {
            try reported.response(forPart: 1, processExitCode: 7, body: Data())
        }
    }

    @Test("both parallel formats ask each section for its own exit code")
    func formatsCarryExitCode() {
        #expect(S3SegmentWriteOut.format(forSegment: 3).contains("s3-seg3-exit=%{exitcode}\\n"))
        #expect(S3PartWriteOut.format(forPart: 2).contains("s3-part2-exit=%{exitcode}\\n"))
    }
}
