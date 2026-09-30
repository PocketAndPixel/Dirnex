import DirnexCore
import Testing

@testable import Dirnex

/// Which refusal is which, for the connect sheet's bucket picker.
///
/// This is the one rule Slice 7 rests on, and it is invisible from the status alone: probed
/// 2026-08-13 against an endpoint that verifies SigV4 by hand, a key **without**
/// `s3:ListAllMyBuckets` and a key with a **wrong secret** both answer HTTP 403, and only the
/// `<Code>` element separates them. Getting it backwards fails in both directions and both are bad:
/// a properly scoped key would be told its credentials are wrong (they are not), and a genuinely
/// mistyped secret would be told to type the bucket name (which will fail next).
@Suite("S3 bucket lister classification")
struct S3BucketListerTests {
    private func error(_ code: String, status: Int = 403) -> S3ServiceError {
        S3ServiceError(status: status, code: code, message: "irrelevant")
    }

    @Test("a key that may not list buckets is not a credential problem")
    func accessDeniedIsPermission() {
        #expect(S3BucketLister.classify(error("AccessDenied")) == .notPermitted)
    }

    @Test("a refused signature and an unknown key are credential problems", arguments: [
        "SignatureDoesNotMatch", "InvalidAccessKeyId"
    ])
    func credentialCodes(code: String) {
        #expect(S3BucketLister.classify(error(code)) == .badCredentials)
    }

    /// A server refusing with its own vocabulary still lands on the permission answer rather than
    /// on an alarming sentence about credentials that are fine — the status carries the meaning
    /// once the two credential codes are ruled out.
    @Test("an unrecognized 403 is read as permission, not as bad credentials")
    func unknownForbiddenCodeIsPermission() {
        #expect(S3BucketLister.classify(error("SomeVendorCode")) == .notPermitted)
        #expect(S3BucketLister.classify(error("")) == .notPermitted)
    }

    @Test("anything that is not a 403 is neither", arguments: [500, 404, 301])
    func otherStatusesAreUnreachable(status: Int) {
        #expect(S3BucketLister.classify(error("NoSuchBucket", status: status)) == .unreachable)
    }

    /// A credential code outside 403 is still a credential problem: `isCredentialFailure` is keyed
    /// on the code, and it is checked first for that reason.
    @Test("a credential code decides regardless of the status it arrived under")
    func credentialCodeWinsOverStatus() {
        #expect(S3BucketLister.classify(error("InvalidAccessKeyId", status: 400)) == .badCredentials)
    }
}
