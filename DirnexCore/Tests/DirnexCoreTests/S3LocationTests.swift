import Foundation
import Testing

@testable import DirnexCore

/// The saved-connection value and the URLs it builds.
@Suite("S3Location")
struct S3LocationTests {
    private static let aws = S3Location(
        host: S3Location.awsHost(region: "eu-central-1"),
        bucket: "sentinel-s2-l1c",
        region: "eu-central-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private static let minio = S3Location(
        host: "127.0.0.1",
        port: 9000,
        bucket: "dirnex",
        region: "us-east-1",
        accessKeyID: "minioadmin",
        addressing: .path,
        usesTLS: false
    )

    // MARK: - Descriptor round-trip

    @Test("an AWS connection round-trips through its descriptor")
    func awsRoundTrips() throws {
        let decoded = try #require(S3Location(descriptor: Self.aws.descriptor))
        #expect(decoded == Self.aws)
    }

    @Test("a path-style plain-HTTP connection round-trips through its descriptor")
    func minioRoundTrips() throws {
        // The case the descriptor exists for: addressing and TLS vary independently, and a saved
        // connection that lost either comes back as a different server — `dirnex.127.0.0.1` does
        // not resolve, and `https://` to a plain MinIO does not answer.
        let decoded = try #require(S3Location(descriptor: Self.minio.descriptor))
        #expect(decoded == Self.minio)
        #expect(decoded.addressing == .path)
        #expect(!decoded.usesTLS)
        #expect(decoded.port == 9000)
    }

    @Test("the addressing mode rides in the scheme")
    func schemeCarriesAddressing() {
        #expect(Self.aws.descriptor.hasPrefix("s3://"))
        #expect(Self.minio.descriptor.hasPrefix("s3p://"))
    }

    @Test("s3p is not read as s3 with a stray p")
    func longestSchemeWins() {
        #expect(S3Addressing.matching(descriptor: "s3p://k@h:1/r/b") == .path)
        #expect(S3Addressing.matching(descriptor: "s3://k@h:1/r/b") == .virtualHost)
        #expect(S3Addressing.matching(descriptor: "ftp://k@h:1") == nil)
    }

    @Test("the region survives the round-trip even where the host does not encode it")
    func regionIsExplicit() throws {
        // An AWS host spells its region, and nothing else does. R2 signs against `auto` on a host
        // that names an account; a connection that re-derived the region from the host would fail
        // with a signature error naming nothing the user can act on.
        let r2 = S3Location(
            host: "abc123.r2.cloudflarestorage.com",
            bucket: "media",
            region: "auto",
            accessKeyID: "KEY"
        )
        let decoded = try #require(S3Location(descriptor: r2.descriptor))
        #expect(decoded.region == "auto")
    }

    @Test("a malformed descriptor decodes to nothing")
    func rejectsMalformed() {
        #expect(S3Location(descriptor: "s3://no-at-sign:443/r/b") == nil)
        #expect(S3Location(descriptor: "s3://k@h:443/onlyregion") == nil)
        #expect(S3Location(descriptor: "s3://k@h/r/b") == nil)
        #expect(S3Location(descriptor: "s3://@h:443/r/b") == nil)
        #expect(S3Location(descriptor: "https://k@h:443/r/b") == nil)
    }

    @Test("a backend id is recognized as S3 in both addressing modes")
    func backendIDRecognition() {
        #expect(Self.aws.backendID.isS3)
        #expect(Self.minio.backendID.isS3)
        #expect(!VFSBackendID.local.isS3)
        #expect(Self.aws.backendID.s3Location == Self.aws)
    }

    // MARK: - URLs

    @Test("virtual-host addressing puts the bucket in the hostname")
    func virtualHostURL() {
        #expect(Self.aws.origin == "https://sentinel-s2-l1c.s3.eu-central-1.amazonaws.com")
        #expect(Self.aws.bucketURL == "https://sentinel-s2-l1c.s3.eu-central-1.amazonaws.com/")
    }

    @Test("path addressing puts the bucket in the path and keeps a non-default port")
    func pathStyleURL() {
        #expect(Self.minio.origin == "http://127.0.0.1:9000")
        #expect(Self.minio.bucketURL == "http://127.0.0.1:9000/dirnex/")
    }

    @Test("a default port is left out of the origin")
    func defaultPortIsOmitted() {
        // SigV4 signs the `Host` header, so a redundant `:443` is one more way for a signature to
        // disagree with the server about what was signed.
        #expect(!Self.aws.origin.contains(":443"))
    }

    @Test("an object URL encodes the key but keeps its separators")
    func objectURL() {
        #expect(
            Self.minio.url(forKey: "docs/my file.txt")
                == "http://127.0.0.1:9000/dirnex/docs/my%20file.txt"
        )
        #expect(
            Self.aws.url(forKey: "a/b.txt")
                == "https://sentinel-s2-l1c.s3.eu-central-1.amazonaws.com/a/b.txt"
        )
    }

    @Test("the signature specifier names the provider, region and service")
    func signatureSpecifier() {
        // One spelling reaches AWS, R2, B2 and MinIO alike — `aws:amz` is the provider pair for
        // S3 and for everything that speaks it.
        #expect(Self.aws.signatureSpecifier == "aws:amz:eu-central-1:s3")
        #expect(Self.minio.signatureSpecifier == "aws:amz:us-east-1:s3")
    }

    @Test("an AWS endpoint host is regional, never the legacy global one")
    func awsHostIsRegional() {
        // A bucket addressed through the wrong region answers 301 rather than serving the listing,
        // and the global host is only ever right for us-east-1.
        #expect(S3Location.awsHost(region: "eu-central-1") == "s3.eu-central-1.amazonaws.com")
    }

    // MARK: - Keychain

    @Test("two buckets reached by one key id keep separate Keychain entries")
    func keychainAccountIncludesTheBucket() {
        let other = S3Location(
            host: Self.aws.host,
            bucket: "other-bucket",
            region: Self.aws.region,
            accessKeyID: Self.aws.accessKeyID
        )
        #expect(Self.aws.keychainAccount != other.keychainAccount)
    }

    @Test("the same connection resolves to the same Keychain entry")
    func keychainAccountIsStable() {
        #expect(Self.aws.keychainAccount == Self.aws.keychainAccount)
        #expect(Self.aws.keychainAccount.contains("AKIAEXAMPLE"))
    }
}

/// Reading the server's refusal — which for S3 is the response, not `curl`'s exit code.
@Suite("S3ResponseError")
struct S3ResponseErrorTests {
    /// Real AWS bodies, captured 2026-08-12.
    private static func parse(_ xml: String, status: Int) -> S3ServiceError {
        S3ServiceError.parse(Data(xml.utf8), status: status)
    }

    @Test("a missing bucket is read from the error document")
    func noSuchBucket() {
        let error = Self.parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message>\
            <BucketName>dirnex-no-such-bucket-xyz</BucketName></Error>
            """,
            status: 404
        )
        #expect(error.code == "NoSuchBucket")
        #expect(error.vfsError(for: .local("/x")) == .notFound(.local("/x")))
    }

    @Test("a wrong region hands back the endpoint that would have worked")
    func permanentRedirectCarriesTheEndpoint() {
        // The reason the whole document is parsed rather than just the status: from outside, a
        // wrong region is indistinguishable from a missing bucket, and the server already knows
        // the answer. Real body from a request aimed at eu-west-2 for a eu-central-1 bucket.
        let error = Self.parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>PermanentRedirect</Code><Message>The bucket you are attempting to access \
            must be addressed using the specified endpoint.</Message>\
            <Endpoint>sentinel-s2-l1c.s3.eu-central-1.amazonaws.com</Endpoint></Error>
            """,
            status: 301
        )
        #expect(error.isRegionRedirect)
        #expect(error.correctEndpoint == "sentinel-s2-l1c.s3.eu-central-1.amazonaws.com")
    }

    @Test("a bad key id is told apart from a bucket policy that says no")
    func credentialFailureIsNotAccessDenied() {
        // Both arrive as 403, so the status cannot separate them — and they send the user to
        // different places: one is retyped, the other is a policy they have to go and change.
        let badKey = Self.parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>InvalidAccessKeyId</Code><Message>The AWS Access Key Id you provided \
            does not exist in our records.</Message></Error>
            """,
            status: 403
        )
        let denied = Self.parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
            """,
            status: 403
        )
        #expect(badKey.isCredentialFailure)
        #expect(!denied.isCredentialFailure)
        #expect(denied.vfsError(for: .local("/x")) == .permissionDenied(.local("/x")))
    }

    @Test("a body that is not an S3 error document still classifies by status")
    func nonS3BodyStillClassifies() {
        // A proxy or a captive portal answers with HTML. The status is all there is, and dropping
        // the response on the floor because it did not parse would report nothing at all.
        let error = Self.parse("<html><body>Gateway Timeout</body></html>", status: 504)
        #expect(error.code.isEmpty)
        #expect(error.status == 504)
        #expect(error.vfsError(for: .local("/x")) == .io(path: .local("/x"), code: EIO))
    }

    @Test("curl's exit code classifies only what happened below HTTP")
    func transportFailures() {
        #expect(S3TransportFailure.classify(curlExit: 6) == .couldNotResolveHost)
        #expect(S3TransportFailure.classify(curlExit: 7) == .couldNotConnect)
        #expect(S3TransportFailure.classify(curlExit: 28) == .operationTimedOut)
        #expect(S3TransportFailure.classify(curlExit: 60) == .certificateNotTrusted)
        #expect(S3TransportFailure.classify(curlExit: 99) == .other)
    }

    /// The redirect names its endpoint in a shape this project never builds — bucket-prefixed and
    /// spelled with a dash — so the reader is written against what AWS actually sent (probed
    /// 2026-08-12) rather than against ``S3Location/awsHost(region:)``.
    @Test(
        "a region is recovered from the endpoint the redirect names",
        arguments: [
            ("nasa-nex.s3-us-west-2.amazonaws.com", "us-west-2"),
            ("s3-us-west-2.amazonaws.com", "us-west-2"),
            ("s3.eu-central-1.amazonaws.com", "eu-central-1"),
            ("my.dotted.bucket.s3.ap-south-1.amazonaws.com", "ap-south-1")
        ]
    )
    func recoversRegionFromEndpoint(endpoint: String, region: String) {
        #expect(S3Location.region(fromEndpoint: endpoint) == region)
    }

    @Test("an endpoint that names no region says so")
    func recoversNoRegionWhereThereIsNone() {
        // The legacy global host is only ever right for `us-east-1`, and it does not say so —
        // guessing one from it would sign for a region the server never named.
        #expect(S3Location.region(fromEndpoint: "s3.amazonaws.com") == nil)
        #expect(S3Location.region(fromEndpoint: "storage.example.com") == nil)
        #expect(S3Location.region(fromEndpoint: "") == nil)
    }

    // MARK: - The endpoint field

    /// The shapes a user has in hand: what R2's console hands over, what a MinIO container prints,
    /// and what someone types for a NAS.
    @Test(
        "an endpoint field takes a URL, a bare host, or either with a port",
        arguments: [
            (
                "https://abc123.r2.cloudflarestorage.com",
                "abc123.r2.cloudflarestorage.com",
                nil as Int?,
                true
            ),
            ("http://127.0.0.1:9000", "127.0.0.1", 9000, false),
            ("nas.local:9000", "nas.local", 9000, true),
            ("  s3.us-east-1.amazonaws.com  ", "s3.us-east-1.amazonaws.com", nil, true),
            ("HTTP://Minio.Local", "Minio.Local", nil, false),
            ("[::1]:9000", "[::1]", 9000, true)
        ]
    )
    func parsesEndpoints(text: String, host: String, port: Int?, usesTLS: Bool) throws {
        let endpoint = try #require(S3Endpoint.parse(text))
        #expect(endpoint.host == host)
        #expect(endpoint.port == port)
        #expect(endpoint.usesTLS == usesTLS)
    }

    /// No scheme means TLS — the direction the FTP form's security picker already defaults in.
    /// Stated as its own assertion because it is a decision, not a parse.
    @Test("a scheme-less endpoint is TLS")
    func schemelessEndpointIsSecure() throws {
        #expect(try #require(S3Endpoint.parse("storage.example.com")).usesTLS)
    }

    /// A pasted console URL keeps working; what it must *not* do is quietly name a bucket, which
    /// would then disagree with the bucket field beside it.
    @Test("a path is dropped rather than read as a bucket")
    func endpointDropsPath() throws {
        let endpoint = try #require(S3Endpoint.parse("https://s3.example.com/my-bucket/deep"))
        #expect(endpoint.host == "s3.example.com")
        #expect(endpoint.port == nil)
    }

    @Test(
        "a malformed endpoint is refused rather than repaired",
        arguments: [
            "", "   ", "https://", "host:", "host:abc", "host:0", "host:70000",
            "-flag.example.com", "two hosts.example.com"
        ]
    )
    func refusesMalformedEndpoints(text: String) {
        // A mistyped port that fell back to the default would connect to a server the user did not
        // name, so it is refused where a "be liberal" reading would guess.
        #expect(S3Endpoint.parse(text) == nil)
    }
}
