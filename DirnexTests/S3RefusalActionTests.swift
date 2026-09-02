import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What a refused S3 connect *names*, which is the difference between a sentence the account holder
/// can act on and one that stops exactly where their question starts.
///
/// Reported 2026-09-03: a bucket created in the console the day before listed fine in the account
/// pane and refused to open, and the sheet said "check the bucket policy or the permissions on the
/// key" — true, and silent about which permission. Measured against real AWS in the same session,
/// the service itself had said it outright: *"not authorized to perform: s3:ListBucket on resource:
/// arn:aws:s3:::amzn-s3-bucket-57494 because no identity-based policy allows the s3:ListBucket
/// action"*, while the byte-identical request for the account's other bucket answered 200. So the
/// refusal is exactly a missing action, and ``S3Action`` — added the day before for the *write*
/// paths — already had the vocabulary this sentence was not using.
///
/// **Every assertion is on the IAM token, never on the prose**, which is what makes the suite
/// language-independent: the app test target inherits whatever `AppleLanguages` Dirnex is pinned to
/// (docs/NOTES.md ▸ Localization), so an assertion over English display text fails on the machine of
/// anyone checking a translation. The token is Latin script in all fourteen catalogs by construction
/// — it is pasted into a policy, so a translated one would grant nothing — which makes it the one
/// part of the sentence that is safe to pin and, not coincidentally, the part under test.
@Suite("S3 refusals name the missing IAM action")
@MainActor
struct S3RefusalActionTests {
    private func location(bucket: String = "amzn-s3-bucket-57494") -> S3Location {
        S3Location(
            host: "s3.eu-north-1.amazonaws.com",
            bucket: bucket,
            region: "eu-north-1",
            accessKeyID: "AKIAEXAMPLE",
            addressing: .virtualHost,
            usesTLS: true
        )
    }

    private func account() -> S3Account {
        S3Account(
            host: "s3.eu-north-1.amazonaws.com",
            region: "eu-north-1",
            accessKeyID: "AKIAEXAMPLE",
            addressing: .virtualHost,
            usesTLS: true
        )
    }

    private func refusal(_ code: String, status: Int = 403) -> S3ServiceError {
        S3ServiceError(status: status, code: code, message: "irrelevant — never shown")
    }

    // MARK: - The action is named

    @Test("a denied bucket names s3:ListBucket, the action IAM authorizes the probe under")
    func bucketRefusalNamesListBucket() {
        let detail = PanelViewController.s3RefusalDetail(
            refusal("AccessDenied"),
            location: location()
        )
        // The token the user pastes into a policy. `probeConnection` is a `ListObjectsV2`, which
        // IAM authorizes as `s3:ListBucket` — there is no `s3:ListObjectsV2`, so naming the REST
        // verb would hand over a token that grants nothing (``S3Action``).
        #expect(detail.contains(S3Action.listBucket.iamName))
        #expect(detail.contains("s3:ListBucket"))
        // Still says *which* bucket: an account pane can hold buckets the key may list beside ones
        // it may not, which is the shape the report arrived in.
        #expect(detail.contains("amzn-s3-bucket-57494"))
    }

    @Test("a denied account names s3:ListAllMyBuckets")
    func accountRefusalNamesListAllMyBuckets() {
        let detail = PanelViewController.s3AccountRefusalDetail(
            refusal("AccessDenied"),
            account: account()
        )
        #expect(detail.contains(S3Action.listAllMyBuckets.iamName))
        #expect(detail.contains("s3:ListAllMyBuckets"))
        #expect(detail.contains("s3.eu-north-1.amazonaws.com"))
    }

    /// The whole chain against the bytes AWS actually sent, rather than against an
    /// `S3ServiceError` built by hand.
    ///
    /// Captured live 2026-09-03 from `ListObjectsV2` on the bucket in the report — the account id,
    /// request id and host id are the only things substituted, and none of them is read by anything
    /// under test. It is the *service's* own document, so it settles the one link a hand-made value
    /// cannot: that `parse` really lifts `AccessDenied` out of this shape and the sheet really
    /// reaches the permission branch on it.
    @Test("AWS's own error document reaches the permission branch")
    func realAWSDocumentNamesTheAction() {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>AccessDenied</Code><Message>User: \
        arn:aws:iam::000000000000:user/dirnex-s3-test is not authorized to perform: s3:ListBucket \
        on resource: "arn:aws:s3:::amzn-s3-bucket-57494" because no identity-based policy allows \
        the s3:ListBucket action</Message><RequestId>REDACTED</RequestId>\
        <HostId>REDACTED</HostId></Error>
        """
        let service = S3ServiceError.parse(Data(body.utf8), status: 403, bucketRegion: "eu-north-1")
        #expect(service.code == "AccessDenied")
        let detail = PanelViewController.s3RefusalDetail(service, location: location())
        #expect(detail.contains(S3Action.listBucket.iamName))
        // The token is ours, not AWS's — `S3ServiceError.message` is the *remote's* English, in a
        // language nobody chose, and is diagnostic only. Asserting the prose is absent is what
        // stops the assertion above from being satisfied by a leak of it: the phrase below is the
        // only other place `s3:ListBucket` appears in this response.
        #expect(!detail.contains("not authorized to perform"))
        #expect(!detail.contains("dirnex-s3-test"))
    }

    // MARK: - Narrowness: what must *not* be named

    /// The control that keeps naming a permission from becoming naming one at every 403.
    ///
    /// `InvalidAccessKeyId` and `SignatureDoesNotMatch` arrive under the same status as
    /// `AccessDenied` and are a credential the user **retypes** — telling them a permission is
    /// missing sends them to edit a policy that is fine, which is worse than the vague sentence
    /// this replaces. It is the same rule ``S3ResponseError/vfsError(for:action:)`` keeps in the
    /// core, and it has to be kept again here because the connect sheet composes its own sentence
    /// from the raw `S3ServiceError` and never goes through that mapping.
    @Test(
        "a credential failure names no permission",
        arguments: ["InvalidAccessKeyId", "SignatureDoesNotMatch"]
    )
    func credentialFailureNamesNoPermission(code: String) {
        let bucket = PanelViewController.s3RefusalDetail(refusal(code), location: location())
        let account = PanelViewController.s3AccountRefusalDetail(refusal(code), account: account())
        #expect(!bucket.contains("s3:"))
        #expect(!account.contains("s3:"))
        // Naming *neither* the bucket nor the endpoint is what says this was reported as a
        // credential problem rather than as something about that place, and it is the half a
        // "contains no token" assertion cannot see: measured 2026-09-03, neutering
        // `isCredentialFailure` left the token absent anyway — the `AccessDenied` gate below it
        // catches these codes on the way past — so the control read as inert while the sheet was
        // telling somebody with a mistyped secret that their key had *signed in*. The credential
        // sentence interpolates nothing, so this holds in all fourteen languages.
        #expect(!bucket.contains("amzn-s3-bucket-57494"))
        #expect(!account.contains("s3.eu-north-1.amazonaws.com"))
    }

    /// A 403 that carried no S3 error code is not necessarily a refusal from S3 at all — a proxy or
    /// a captive portal produces one just as easily — so there is no IAM action to name and no
    /// policy to send anyone to. Naming one is the mistake this backend already paid for once, when
    /// a 403 recommended Full Disk Access for an object on somebody else's servers.
    @Test("a 403 with no S3 error code names no permission")
    func codelessRefusalNamesNoPermission() {
        let bucket = PanelViewController.s3RefusalDetail(refusal(""), location: location())
        let account = PanelViewController.s3AccountRefusalDetail(refusal(""), account: account())
        #expect(!bucket.contains("s3:"))
        #expect(!account.contains("s3:"))
    }

    /// The other refusals the bucket sheet words itself, kept out of the permission branch: one is
    /// a name that is not there and one is a region, and neither is a policy to edit.
    @Test("a missing bucket and a bare redirect name no permission", arguments: [
        "NoSuchBucket", "PermanentRedirect",
    ])
    func otherRefusalsNameNoPermission(code: String) {
        let status = code == "NoSuchBucket" ? 404 : 301
        let detail = PanelViewController.s3RefusalDetail(
            refusal(code, status: status),
            location: location()
        )
        #expect(!detail.contains("s3:"))
    }
}
