import Foundation
import Testing

@testable import DirnexCore

/// The account descriptor and the three account-level argument builders (PLAN.md §M21).
///
/// Every claim about what `curl` is told below was checked against a live run on 2026-08-13 — the
/// probe endpoint that recomputes SigV4 by hand for the request shape, and a real S3-compatible
/// account for the semantics. What the tests pin is that the builder keeps producing the shape that
/// was measured working.
@Suite("S3 account identity and arguments")
struct S3AccountIdentityTests {
    private static let account = S3Account(
        host: "s3.lax.sharktech.net",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE",
        addressing: .path
    )

    // MARK: - Descriptor

    @Test("an account descriptor round-trips in both addressing modes")
    func descriptorRoundTrips() throws {
        for addressing in S3Addressing.allCases {
            let account = S3Account(
                host: "s3.example.com",
                port: 9000,
                region: "eu-west-1",
                accessKeyID: "KEY",
                addressing: addressing,
                usesTLS: false
            )
            let recovered = try #require(S3Account(descriptor: account.descriptor))
            #expect(recovered == account)
        }
    }

    /// The whole reason account descriptors get their own scheme pair: a bucket id read as an
    /// account would list the endpoint's buckets under a pane the user opened on their files.
    @Test("account and bucket descriptors can never be read as each other")
    func accountAndBucketDescriptorsAreDisjoint() {
        let location = S3Location(
            host: "s3.example.com",
            bucket: "photos",
            region: "eu-west-1",
            accessKeyID: "KEY"
        )
        let account = location.account

        #expect(location.backendID.isS3)
        #expect(!location.backendID.isS3Account)
        #expect(account.backendID.isS3Account)
        #expect(!account.backendID.isS3)
        #expect(S3Account(descriptor: location.descriptor) == nil)
        #expect(S3Location(descriptor: account.descriptor) == nil)
    }

    @Test("an account carries its addressing mode to the buckets reached from it")
    func carriesAddressingToItsBuckets() {
        let account = S3Account(
            host: "s3.example.com",
            region: "eu-west-1",
            accessKeyID: "KEY",
            addressing: .path
        )
        #expect(account.bucketLocation(named: "photos").addressing == .path)
        // And the round trip through a bucket and back preserves it.
        #expect(account.bucketLocation(named: "photos").account == account)
    }

    /// A bucket list spans regions while an account is signed for one, so a row that named its own
    /// region is entered with that region rather than the account's.
    @Test("a bucket's own region overrides the account's")
    func aBucketsOwnRegionWins() {
        let location = Self.account.bucketLocation(named: "photos", region: "ap-south-1")
        #expect(location.region == "ap-south-1")
        #expect(Self.account.bucketLocation(named: "photos").region == "us-east-1")
    }

    @Test("an account's Keychain entry cannot collide with one of its buckets'")
    func keychainAccountsAreDisjoint() {
        let bucket = Self.account.bucketLocation(named: "photos")
        #expect(Self.account.keychainAccount != bucket.keychainAccount)
        #expect(bucket.keychainAccount.hasPrefix(Self.account.keychainAccount))
    }

    @Test("a malformed descriptor is refused rather than half-parsed")
    func refusesMalformedDescriptors() {
        #expect(S3Account(descriptor: "s3a://KEY@host:443") == nil) // no region
        #expect(S3Account(descriptor: "s3a://KEY@host:443/eu/extra") == nil) // a bucket's shape
        #expect(S3Account(descriptor: "s3a://@host:443/eu") == nil) // no key id
        #expect(S3Account(descriptor: "s3a://KEY@host:notaport/eu") == nil)
        #expect(S3Account(descriptor: "ftp://KEY@host:443/eu") == nil)
    }

    // MARK: - Arguments

    @Test("the secret never reaches argv on any account verb")
    func noSecretInArgv() {
        let all = [
            S3ProcessArguments.listBuckets(account: Self.account),
            S3ProcessArguments.createBucket(account: Self.account, name: "photos"),
            S3ProcessArguments.deleteBucket(account: Self.account, name: "photos"),
            S3ProcessArguments.headBucket(account: Self.account, name: "photos")
        ]
        for arguments in all {
            #expect(arguments.contains("-K"))
            #expect(arguments.contains("-"))
            #expect(!arguments.contains { $0.contains("secret") })
            #expect(arguments.contains("--aws-sigv4"))
        }
    }

    /// Path-style, because that is what a single-label wildcard certificate forces — and it is the
    /// URL the live run actually created and deleted a bucket with.
    @Test("the bucket URL is the location's own, in both addressing modes")
    func bucketURLIsTheLocationsOwn() {
        let create = S3ProcessArguments.createBucket(account: Self.account, name: "photos")
        #expect(create.last == "https://s3.lax.sharktech.net/photos/")

        let virtualHost = S3Account(
            host: "s3.eu-west-1.amazonaws.com",
            region: "eu-west-1",
            accessKeyID: "KEY",
            addressing: .virtualHost
        )
        let delete = S3ProcessArguments.deleteBucket(account: virtualHost, name: "photos")
        #expect(delete.last == "https://photos.s3.eu-west-1.amazonaws.com/")
    }

    @Test("create sends the region body everywhere except us-east-1")
    func sendsTheRegionBodyExceptInUSEast1() {
        #expect(S3ProcessArguments.createBucketBody(region: "us-east-1") == nil)

        let body = S3ProcessArguments.createBucketBody(region: "eu-west-1")
        let unwrapped = body ?? ""
        #expect(unwrapped.contains("<LocationConstraint>eu-west-1</LocationConstraint>"))
        #expect(unwrapped.contains("CreateBucketConfiguration"))
    }

    /// `-T` would append the local file's basename to a URL ending in `/`, and `-T /dev/null` sends
    /// chunked framing S3 refuses. `--data-binary` states its own emptiness with a real digest.
    @Test("create never uses -T, and always states a body")
    func createStatesItsOwnBody() {
        let plain = S3ProcessArguments.createBucket(account: Self.account, name: "photos")
        #expect(!plain.contains("--upload-file"))
        #expect(!plain.contains("-T"))
        #expect(plain.contains("--data-binary"))

        let regional = S3Account(
            host: "s3.eu-west-1.amazonaws.com",
            region: "eu-west-1",
            accessKeyID: "KEY"
        )
        let withRegion = S3ProcessArguments.createBucket(account: regional, name: "photos")
        #expect(withRegion.contains("--data-binary"))
        #expect(withRegion.contains("Content-Type: application/xml"))
    }

    @Test("head reads the size and region without downloading a body")
    func headDownloadsNothing() {
        let arguments = S3ProcessArguments.headBucket(account: Self.account, name: "photos")
        #expect(arguments.contains("--head"))
        #expect(arguments.contains("/dev/null"))
        // The region rides the write-out that every S3 invocation already carries.
        #expect(arguments.contains { $0.contains("x-amz-bucket-region") })
    }
}
