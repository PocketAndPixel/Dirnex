import Foundation
import Testing

@testable import DirnexCore

/// Naming the IAM action behind a `403 AccessDenied`, so the sentence says what to fix.
///
/// The measurement these rest on, taken against real AWS on 2026-09-02 with a key scoped to one
/// bucket: `CreateBucket` answered *"not authorized to perform: s3:CreateBucket … because no
/// identity-based policy allows the s3:CreateBucket action"* for three different names, while the
/// byte-identical request for the single name that account's policy grants answered **200**. So the
/// refusal really is one missing action, and the old sentence — "this account may not have
/// permission for it" — stopped exactly where the answer started.
@Suite("S3 — naming the refused IAM action")
struct S3ActionNotPermittedTests {
    private static let account = S3Account(
        host: "s3.eu-north-1.amazonaws.com",
        region: "eu-north-1",
        accessKeyID: "AKIAEXAMPLE",
        addressing: .virtualHost
    )

    private var root: VFSPath { VFSPath(backend: .s3Account(Self.account), path: "/") }

    private func path(_ bucket: String) -> VFSPath {
        VFSPath(backend: .s3Account(Self.account), path: "/\(bucket)")
    }

    private func backend(_ transport: FakeS3AccountTransport) -> S3AccountBackend {
        S3AccountBackend(account: Self.account, transport: transport)
    }

    private static func errorBody(_ code: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?><Error><Code>\(code)</Code>\
        <Message>whatever the server says, in whatever language</Message></Error>
        """.utf8)
    }

    private func denied(_ code: String = "AccessDenied", status: Int = 403) -> S3ServiceError {
        S3ServiceError.parse(Self.errorBody(code), status: status)
    }

    // MARK: - The reported gesture

    /// F7 on an account pane, which is where this started: the bucket name is refused and the
    /// sentence has to name `s3:CreateBucket`.
    @Test("a refused bucket create names s3:CreateBucket")
    func createNamesItsAction() {
        let transport = FakeS3AccountTransport()
        transport.headResponse = S3Response(status: 404, body: Self.errorBody("NoSuchBucket"))
        transport.createResponse = S3Response(status: 403, body: Self.errorBody("AccessDenied"))

        let expected = VFSError.unsupported(.s3ActionNotPermitted(action: .createBucket))
        #expect(throws: expected) {
            try backend(transport).createDirectory(at: path("amzm-s3-bucket-29635"))
        }
    }

    /// The sibling gesture, so F8 is not left holding the sentence F7 just stopped using.
    @Test("a refused bucket delete names s3:DeleteBucket")
    func deleteNamesItsAction() {
        let transport = FakeS3AccountTransport()
        transport.deleteResponse = S3Response(status: 403, body: Self.errorBody("AccessDenied"))

        let expected = VFSError.unsupported(.s3ActionNotPermitted(action: .deleteBucket))
        #expect(throws: expected) {
            try backend(transport).removeItem(at: path("amzn-s3-df"))
        }
    }

    /// `ListAllMyBuckets` is the request a bucket-scoped key most often cannot make — the ordinary
    /// way these are issued — so the account pane's own listing is the third gesture that earns it.
    @Test("a refused account listing names s3:ListAllMyBuckets")
    func listingNamesItsAction() {
        let transport = FakeS3AccountTransport()
        transport.listPages = [S3Response(status: 403, body: Self.errorBody("AccessDenied"))]

        let expected = VFSError.unsupported(.s3ActionNotPermitted(action: .listAllMyBuckets))
        #expect(throws: expected) {
            try backend(transport).listDirectory(at: root)
        }
    }

    // MARK: - Narrowness

    /// **The control that matters most.** A 403 also carries the two credential failures, which are
    /// a key the user *retypes* — telling them a permission is missing would send them to edit a
    /// policy that is fine. Keyed on the `<Code>`, never on the status.
    @Test("a bad key is not reported as a missing permission", arguments: [
        "InvalidAccessKeyId", "SignatureDoesNotMatch"
    ])
    func credentialFailuresKeepTheGenericSentence(_ code: String) {
        let target = path("amzn-s3-df")
        let mapped = denied(code).vfsError(for: target, action: .createBucket)
        #expect(mapped == .permissionDenied(target))
    }

    /// Strictly additive: a caller that does not know its own verb passes none and gets exactly
    /// what it got before. Without this, "name the action" could quietly become "name a guess".
    @Test("a caller with no action keeps the generic mapping")
    func noActionIsUnchanged() {
        let target = path("amzn-s3-df")
        #expect(denied().vfsError(for: target) == .permissionDenied(target))
    }

    /// `InvalidObjectState` is a 403 too, and it already had a sentence that is *more* specific
    /// than a missing permission — an archived object needs restoring on the service, not a policy
    /// edit. The `<Code>` checks run before this one, and this pins that order.
    @Test("an archived object keeps its own sentence, not a permission one")
    func archivedObjectOutranksTheActionSentence() {
        let target = path("amzn-s3-df")
        let mapped = denied("InvalidObjectState").vfsError(for: target, action: .getObject)
        #expect(mapped == .unsupported(.objectNotRestored(name: "amzn-s3-df")))
    }

    /// A refusal that is not about permissions at all must not borrow the sentence just because a
    /// verb was named.
    @Test("a 404 still reads as not found even when the action is known")
    func otherStatusesAreUntouched() {
        let target = path("amzn-s3-df")
        let missing = S3ServiceError.parse(Self.errorBody("NoSuchBucket"), status: 404)
        #expect(missing.vfsError(for: target, action: .listBucket) == .notFound(target))
    }

    // MARK: - The tokens themselves

    /// A misspelled action is worse than no action — the user would paste it into a policy and it
    /// would grant nothing. These are IAM action names, **not** REST verbs: there is no
    /// `s3:HeadBucket` or `s3:HeadObject`, so `HeadBucket` rides on `s3:ListBucket` and `HeadObject`
    /// on `s3:GetObject`. Spelled out here rather than derived from the case names, which is the
    /// only way this test can disagree with the enum.
    @Test("every action carries its real IAM name")
    func iamNamesAreExact() {
        let expected: [S3Action: String] = [
            .createBucket: "s3:CreateBucket",
            .deleteBucket: "s3:DeleteBucket",
            .listAllMyBuckets: "s3:ListAllMyBuckets",
            .listBucket: "s3:ListBucket",
            .getObject: "s3:GetObject",
            .putObject: "s3:PutObject",
            .deleteObject: "s3:DeleteObject"
        ]
        #expect(Set(expected.keys) == Set(S3Action.allCases))
        for action in S3Action.allCases {
            #expect(action.iamName == expected[action])
        }
    }

    /// The sentence has to carry the token through to the screen — a named reason whose argument
    /// never reaches the format would render the same uninformative line the old mapping did.
    @Test("the sentence names the action")
    func sentenceCarriesTheToken() {
        let reason = VFSUnsupportedReason.s3ActionNotPermitted(action: .createBucket)
        #expect(reason.arguments == ["s3:CreateBucket"])
        #expect(reason.sentence.contains("s3:CreateBucket"))
        #expect(reason.key == "s3ActionNotPermitted")
    }
}
