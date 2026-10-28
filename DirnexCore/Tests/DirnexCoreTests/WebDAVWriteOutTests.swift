import Foundation
import Testing

@testable import DirnexCore

/// Reading one `curl` run (PLAN.md §M32 Slice 2). Every stderr here was captured from a real run
/// against the NAS or macOS's Apache with the shipped format, so the reader is held to `curl`'s
/// bytes rather than to a test's idea of them.
@Suite("WebDAVWriteOut")
struct WebDAVWriteOutTests {
    @Test("the labelled fields and the headers are read from a real 401")
    func readsNASChallenge() throws {
        let fields = try WebDAVWriteOut.parse(
            stderr: WebDAVFixtures.text("curl-exit0-nas-propfind-401", extension: "stderr")
        )
        #expect(fields.status == 401)
        #expect(fields.bytesDownloaded == 381)
        #expect(fields.bytesUploaded == 201)
        #expect(fields.headers["www-authenticate"] == [#"Basic realm="SYNO_WebDAV Storage""#])
        #expect(fields.headers["content-type"] == ["text/html; charset=iso-8859-1"])
    }

    @Test("a header sent twice keeps both values, in order")
    func repeatedHeaders() throws {
        let fields = try WebDAVWriteOut.parse(
            stderr: WebDAVFixtures.text("curl-exit0-nas-options-200", extension: "stderr")
        )
        #expect(fields.headers["dav"] == ["1,2", "<http://apache.org/dav/propset/fs/1>"])
        let multi = try WebDAVWriteOut.parse(
            stderr: WebDAVFixtures.text("curl-exit0-apache-multi-401", extension: "stderr")
        )
        #expect(multi.headers["www-authenticate"] == [
            "Negotiate", "NTLM", #"Basic realm="dirnex-multi""#
        ])
    }

    /// Why the format carries `%{header_json}` rather than `%header{www-authenticate}`: the latter
    /// prints the first of several headers only, and here that is `Negotiate` — a server Dirnex can
    /// log in to read as one it cannot.
    @Test("the first challenge alone would hide the Basic one the server also offers")
    func firstHeaderAloneMisleads() throws {
        let response = try WebDAVFixtures.run("curl-exit0-apache-multi-401")
        let first = try #require(response.value("www-authenticate"))
        #expect(WebDAVChallenge.schemes(in: [first]) == ["negotiate"])
        #expect(WebDAVChallenge.schemes(in: response.values("www-authenticate")).contains("basic"))
    }

    @Test("curl's prose before the write-out is ignored, and no answer is status 0")
    func proseAndNoAnswer() throws {
        let untrusted = try WebDAVFixtures.text(
            "curl-exit60-nas-https-untrusted",
            extension: "stderr"
        )
        #expect(untrusted.hasPrefix("curl: (60)"))
        let fields = WebDAVWriteOut.parse(stderr: untrusted)
        #expect(fields.status == 0)
        #expect(fields.headers.isEmpty)
    }

    @Test("a header block that does not parse leaves the status standing")
    func malformedHeaders() {
        let fields = WebDAVWriteOut.parse(
            stderr: "dav-status=207\ndav-size=12\ndav-headers={\"dav\":["
        )
        #expect(fields.status == 207)
        #expect(fields.bytesDownloaded == 12)
        #expect(fields.headers.isEmpty)
    }

    @Test("the format puts the headers last, after the switch to stderr")
    func formatShape() {
        #expect(WebDAVWriteOut.format.hasPrefix("%{stderr}"))
        #expect(WebDAVWriteOut.format.hasSuffix("dav-headers=%{header_json}\\n"))
        #expect(!WebDAVWriteOut.format.contains("%header{"))
    }

    // MARK: - Exit code before status

    @Test("exit 0 with a status is a response, whatever the status")
    func exitZeroIsAResponse() throws {
        let response = try WebDAVFixtures.run(
            "curl-exit0-nas-propfind-404",
            body: "nas-missing-404",
            bodyExtension: "html"
        )
        #expect(response.status == 404)
        #expect(!response.isSuccess)
        #expect(String(bytes: response.body, encoding: .utf8)?.contains("404 Not Found") == true)
    }

    @Test("--fail's exit 22 is a refusal the server sent, so a response")
    func failExitIsAResponse() throws {
        let response = try WebDAVFixtures.run("curl-exit22-nas-get-404")
        #expect(response.status == 404)
    }

    /// The measurement that sets this reader apart from S3's: a status of 200 and a file a sixth
    /// downloaded. Read by status alone, it is a finished copy.
    @Test("a download cut short by the time budget is a transport failure, not a 200")
    func cutShortIsNotSuccess() throws {
        let stderr = try WebDAVFixtures.text("curl-exit28-nas-get-cut", extension: "stderr")
        #expect(WebDAVWriteOut.parse(stderr: stderr).status == 200)
        #expect(WebDAVWriteOut.parse(stderr: stderr).bytesDownloaded == 584_179)
        #expect(throws: WebDAVResponseError.transport(.operationTimedOut)) {
            try WebDAVWriteOut.response(exitCode: 28, standardOutput: Data(), standardError: stderr)
        }
    }

    @Test("no answer at all is classified by the exit code")
    func noAnswer() {
        #expect(throws: WebDAVResponseError.transport(.operationTimedOut)) {
            try WebDAVFixtures.run("curl-exit28-unreachable")
        }
        #expect(throws: WebDAVResponseError.transport(.certificateNotTrusted)) {
            try WebDAVFixtures.run("curl-exit60-nas-https-untrusted")
        }
    }

    @Test("exit 22 without a refusal's status is not taken for one")
    func failExitNeedsARefusal() {
        #expect(throws: WebDAVResponseError.transport(.other)) {
            try WebDAVWriteOut.response(
                exitCode: 22,
                standardOutput: Data(),
                standardError: "dav-status=200\ndav-headers={}\n"
            )
        }
    }
}
