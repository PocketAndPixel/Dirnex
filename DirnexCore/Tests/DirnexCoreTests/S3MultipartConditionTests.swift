import Foundation
import Testing

@testable import DirnexCore

/// The **multipart** half of the conditional write (PLAN.md §M21 Slice 19).
///
/// Split from `S3WriteConditionTests` when that file reached SwiftLint's ceilings, and split by
/// concept rather than shaved: what these tests are about is one request — the completion — where
/// everything the single-`PUT` path took for granted is different. It is the request the object's
/// *existence* hangs on rather than the one that moves the bytes; it can refuse under a status it
/// has already committed to; and a refusal there leaves parts stored on the server.
///
/// All three shapes below were measured against an endpoint that recomputes SigV4 by hand, with a
/// wrong-secret control refused in the same run — a `HTTP=412`, the same refusal driven into
/// AWS's documented `HTTP=200` late-failure shape, and the upload still open afterwards. What
/// remains unmeasurable from any client is whether a given server honours the header at all, which
/// is why none of this is allowed to *claim* protection (``S3WriteConditionUnsupported``).
@Suite("S3 conditional multipart writes")
struct S3MultipartConditionTests {
    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "1000genomes",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private var session: S3Session { S3Session(location: location) }

    private func backend(_ transport: FakeS3Transport) -> S3Backend {
        S3Backend(location: location, transport: transport)
    }

    private func path(_ value: String) -> VFSPath {
        VFSPath(backend: .s3(location), path: value)
    }

    private func temporaryFile(bytes: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-multipart-condition-\(UUID().uuidString)")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url.path
    }

    /// The precondition rides on the **completion**, which is the request the object's existence
    /// hangs on — so a large save-back is guarded exactly as a small one is.
    ///
    /// Both halves are asserted, and the second is what makes the first mean anything: that the
    /// upload really went the multipart way (a single `PUT` carrying the header would satisfy
    /// `conditionWasSent` for the wrong reason), and that the condition reached the transport
    /// **once** — on the completion and not on the parts, which carry no precondition and must not
    /// start.
    @Test("a large upload carries its condition on the completion")
    func multipartCarriesTheCondition() throws {
        let transport = FakeS3Transport()
        let big = try temporaryFile(bytes: Int(S3MultipartLimits.multipartThreshold) + 1024)
        defer { try? FileManager.default.removeItem(atPath: big) }

        let result = try backend(transport).upload(
            localPath: big,
            over: path("/big.bin"),
            condition: .ifMatches(entityTag: "\"abc\""),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(result.conditionWasSent)
        #expect(transport.writes.contains { if case .createMultipart = $0 { true } else { false } })
        #expect(transport.conditions == [.ifMatches(entityTag: "\"abc\"")])
    }

    /// The narrowness control for the one above: an *unconditional* large upload — every F5 to a
    /// bucket — must reach the completion with nothing attached, and must still say so.
    @Test("an unconditional large upload attaches nothing and reports nothing")
    func multipartWithoutAConditionIsUnchanged() throws {
        let transport = FakeS3Transport()
        let big = try temporaryFile(bytes: Int(S3MultipartLimits.multipartThreshold) + 1024)
        defer { try? FileManager.default.removeItem(atPath: big) }

        let result = try backend(transport).upload(
            localPath: big,
            over: path("/big.bin"),
            condition: .unconditional,
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(!result.conditionWasSent)
        #expect(transport.conditions == [.unconditional])
    }

    /// The completion's arguments: the same request as before plus the header, and the header
    /// **before** the URL, since `curl` reads the URL as the end of the invocation.
    @Test("the completion keeps its manifest shape and gains only the header")
    func completeMultipartArguments() {
        let plain = S3ProcessArguments.completeMultipartUpload(
            session: session,
            key: "docs/big.bin",
            uploadID: "upload-7",
            bodyPath: "/tmp/manifest.xml"
        )
        let guarded = S3ProcessArguments.completeMultipartUpload(
            session: session,
            key: "docs/big.bin",
            uploadID: "upload-7",
            bodyPath: "/tmp/manifest.xml",
            condition: .ifMatches(entityTag: "\"abc\"")
        )
        #expect(!plain.contains("If-Match: \"abc\""))
        #expect(guarded.contains("If-Match: \"abc\""))
        // Everything else is untouched — the POST, the manifest travelling as a file, the content
        // type, and the upload id percent-encoded into the query. Asserted by *removing* the two
        // arguments the condition adds and demanding the rest be identical, which is what says the
        // header was added rather than something else having quietly changed with it.
        var stripped = guarded
        if let index = stripped.firstIndex(of: "If-Match: \"abc\"") {
            stripped.remove(at: index)
            stripped.remove(at: index - 1) // the "-H" that carried it
        }
        #expect(stripped == plain)
        // And it goes before the URL, which `curl` reads as the end of the invocation.
        #expect(guarded.last == plain.last)
    }

    /// **The finding this slice turns on.** A completion may refuse under a status it has already
    /// committed to — measured, `HTTP=200` carrying `<Code>PreconditionFailed</Code>` — where the
    /// status-only reading every other verb uses answers "success" and the object silently does not
    /// exist. Two claims: the refusal is read at all, and it is read as a *conflict* rather than as
    /// a generic failure.
    @Test("a refusal inside a 200 is still read as somebody else's edit")
    func refusalCommittedToASuccessStatus() throws {
        let transport = FakeS3Transport()
        transport.completeMultipartResponse = S3Response(
            status: 200,
            body: Data(preconditionFailedDocument.utf8)
        )
        let big = try temporaryFile(bytes: Int(S3MultipartLimits.multipartThreshold) + 1024)
        defer { try? FileManager.default.removeItem(atPath: big) }

        #expect(throws: VFSError.unsupported(.remoteFileChangedSinceFetch(name: "big.bin"))) {
            try backend(transport).upload(
                localPath: big,
                over: path("/big.bin"),
                condition: .ifMatches(entityTag: "\"abc\""),
                progress: { _ in },
                isCancelled: { false }
            )
        }
    }

    /// The same refusal arriving the ordinary way — as a 412 — which `conditionallyWrite` reads and
    /// the body reading above structurally cannot. Both paths exist because a given server takes
    /// one of them and no client can choose.
    @Test("a refusal arriving as a 412 status reads the same way")
    func refusalAsAStatus() throws {
        let transport = FakeS3Transport()
        transport.completeMultipartResponse = S3Response(
            status: 412,
            body: Data(preconditionFailedDocument.utf8)
        )
        let big = try temporaryFile(bytes: Int(S3MultipartLimits.multipartThreshold) + 1024)
        defer { try? FileManager.default.removeItem(atPath: big) }

        #expect(throws: VFSError.unsupported(.remoteFileChangedSinceFetch(name: "big.bin"))) {
            try backend(transport).upload(
                localPath: big,
                over: path("/big.bin"),
                condition: .ifMatches(entityTag: "\"abc\""),
                progress: { _ in },
                isCancelled: { false }
            )
        }
    }

    /// A refused completion leaves the upload **open**, and its parts are stored and billed until
    /// something releases them — measured on the probe endpoint, which still held the upload after
    /// answering 412. The abort already runs on every failing exit, and this is what says a refusal
    /// counts as one: without it, conditioning a large upload would trade a lost write for a
    /// standing charge the user cannot see in any listing.
    @Test("a refused completion still aborts the upload")
    func refusedCompletionReleasesItsParts() throws {
        let transport = FakeS3Transport()
        transport.completeMultipartResponse = S3Response(
            status: 200,
            body: Data(preconditionFailedDocument.utf8)
        )
        let big = try temporaryFile(bytes: Int(S3MultipartLimits.multipartThreshold) + 1024)
        defer { try? FileManager.default.removeItem(atPath: big) }

        _ = try? backend(transport).upload(
            localPath: big,
            over: path("/big.bin"),
            condition: .ifMatches(entityTag: "\"abc\""),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(transport.writes.contains { if case .abortMultipart = $0 { true } else { false } })
    }

    /// The narrowness control for the body reading: a completion that fails for a reason the
    /// precondition did not cause keeps its own diagnosis. Reporting an `AccessDenied` as a
    /// conflict would send the user looking for an edit nobody made.
    @Test("a completion failure the precondition did not cause is not read as a conflict")
    func unrelatedCompletionFailureIsUntouched() throws {
        let transport = FakeS3Transport()
        transport.completeMultipartResponse = S3Response(
            status: 200,
            body: Data("""
            <?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code>\
            <Message>Access Denied</Message></Error>
            """.utf8)
        )
        let big = try temporaryFile(bytes: Int(S3MultipartLimits.multipartThreshold) + 1024)
        defer { try? FileManager.default.removeItem(atPath: big) }

        let thrown = #expect(throws: VFSError.self) {
            try backend(transport).upload(
                localPath: big,
                over: path("/big.bin"),
                condition: .ifMatches(entityTag: "\"abc\""),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        if case .unsupported = thrown { Issue.record("an unrelated failure read as a conflict") }
    }

    private let preconditionFailedDocument = """
    <?xml version="1.0" encoding="UTF-8"?><Error><Code>PreconditionFailed</Code>\
    <Message>At least one of the preconditions failed.</Message></Error>
    """
}
