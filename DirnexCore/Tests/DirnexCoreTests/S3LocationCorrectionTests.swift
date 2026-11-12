import Foundation
import Testing

@testable import DirnexCore

/// The two corrections a bucket connection makes without asking anyone, now that a connect and a
/// search across an account both ask them (PLAN.md §M38 Slice 5).
@Suite("S3 location correction")
struct S3LocationCorrectionTests {
    private let aws = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "nasa-nex",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private let compatible = S3Location(
        host: "s3.lax.sharktech.net",
        port: 8443,
        bucket: "dirnex-test",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE",
        addressing: .path
    )

    private func redirect(naming region: String?) -> S3ServiceError {
        S3ServiceError.parse(
            Data(S3Fixtures.wrongRegion.utf8),
            status: 301,
            bucketRegion: region
        )
    }

    // MARK: - Region

    /// AWS's 301 is a complaint about the host, so re-signing for the new region while still
    /// addressing the old host earns the same redirect again.
    @Test("a redirect on AWS moves the region and the host with it")
    func redirectMovesAnAWSHost() throws {
        let moved = try #require(S3LocationCorrection.afterRefusal(
            redirect(naming: "us-west-2"),
            at: aws
        ))

        #expect(moved.region == "us-west-2")
        #expect(moved.host == "s3.us-west-2.amazonaws.com")
        #expect(moved.bucket == aws.bucket && moved.accessKeyID == aws.accessKeyID)
    }

    /// The endpoint's element is the fallback when the header is missing, and it arrives in the
    /// dash spelling `s3-us-west-2` (the captured 301).
    @Test("a redirect with no header is read from its endpoint")
    func redirectReadsTheEndpoint() throws {
        let moved = try #require(S3LocationCorrection.afterRefusal(redirect(naming: nil), at: aws))
        #expect(moved.region == "us-west-2")
    }

    @Test("an S3-compatible host stays where the user put it")
    func compatibleHostStays() throws {
        let moved = compatible.movingRegion(to: "lax")

        #expect(moved.host == compatible.host)
        #expect(moved.port == 8443)
        #expect(moved.addressing == .path)
        #expect(moved.region == "lax")
    }

    @Test("a redirect naming the region already used corrects nothing")
    func sameRegionIsNotACorrection() {
        #expect(S3LocationCorrection.afterRefusal(redirect(naming: "us-east-1"), at: aws) == nil)
    }

    @Test("a refusal that is not a redirect corrects nothing")
    func otherRefusalsAreNotCorrections() {
        let denied = S3ServiceError(status: 403, code: "AccessDenied", message: "Access Denied")
        #expect(S3LocationCorrection.afterRefusal(denied, at: aws) == nil)
    }

    // MARK: - Addressing

    @Test("an untrusted certificate under virtual-host addressing retries path-style")
    func certificateRetriesPathStyle() throws {
        let retry = try #require(S3LocationCorrection.afterTransportFailure(
            S3ResponseError.transport(.certificateNotTrusted),
            at: aws
        ))
        #expect(retry == aws.addressed(.path))
    }

    /// Path-style already verifies the host the user typed, so a certificate failure there is the
    /// endpoint's, and retrying would loop.
    @Test("an untrusted certificate path-style has nothing left to correct")
    func pathStyleCertificateIsFinal() {
        #expect(S3LocationCorrection.afterTransportFailure(
            S3ResponseError.transport(.certificateNotTrusted),
            at: compatible
        ) == nil)
    }

    @Test("a failure other than the certificate is not about addressing")
    func otherFailuresAreNotAddressing() {
        #expect(S3LocationCorrection.afterTransportFailure(
            S3ResponseError.transport(.couldNotConnect),
            at: aws
        ) == nil)
        #expect(S3LocationCorrection.afterTransportFailure(CancellationError(), at: aws) == nil)
    }
}

/// The bounded flat listing an account search lists each bucket with (PLAN.md §M38 Slice 5), on the
/// backend directly.
@Suite("S3 bounded subtree listing")
struct S3BoundedSubtreeTests {
    private typealias Fixtures = S3AccountSearchFixtures

    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "bucket",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private var root: VFSPath { VFSPath(backend: .s3(location), path: "/") }

    @Test("a page handed over is not asked for again")
    func usesTheGivenFirstPage() throws {
        let transport = FakeS3Transport()
        transport.listPages = [Fixtures.page(["b.txt"])]
        let first = try S3ListingParser.parse(Fixtures.page(["a.txt"], next: "t1").body)

        let listing = try S3Backend(location: location, transport: transport).boundedSubtreeListing(
            at: root,
            objectLimit: 10,
            firstPage: first
        )

        #expect(listing.entries.map(\.name) == ["a.txt", "b.txt"])
        #expect(listing.isComplete)
        #expect(
            transport.listRequests == [.init(prefix: "", delimiter: nil, continuationToken: "t1")]
        )
    }

    /// A marker is an object to S3, so it counts toward the bound like any other key — and the
    /// folder it names still becomes a row.
    @Test("a directory marker counts toward the bound")
    func markersCount() throws {
        let transport = FakeS3Transport()
        transport.listPages = [Fixtures.page(["docs/", "docs/a.txt", "z.txt"])]

        let listing = try S3Backend(location: location, transport: transport).boundedSubtreeListing(
            at: root,
            objectLimit: 2
        )

        #expect(listing.entries.map(\.name) == ["docs", "a.txt"])
        #expect(!listing.isComplete)
    }

    @Test("a stop part-way returns the pages read rather than throwing")
    func stopReturnsWhatWasRead() throws {
        let transport = FakeS3Transport()
        transport.listPages = [Fixtures.page(["a.txt"], next: "t1"), Fixtures.page(["b.txt"])]

        let listing = try S3Backend(location: location, transport: transport).boundedSubtreeListing(
            at: root,
            objectLimit: 10,
            isCancelled: { transport.listRequests.count == 1 }
        )

        #expect(listing.entries.map(\.name) == ["a.txt"])
        #expect(!listing.isComplete)
        #expect(transport.listRequests.count == 1)
    }

    /// The runaway guard still stands behind the bound: a bound larger than `pageLimit` pages is
    /// refused at the guard rather than quietly taken as the bound.
    @Test("the page limit still refuses a run past it")
    func pageLimitStillRefuses() throws {
        let transport = FakeS3Transport()
        transport.listPages = [
            Fixtures.page(["a.txt"], next: "t1"),
            Fixtures.page(["b.txt"], next: "t2")
        ]

        #expect(throws: VFSError.self) {
            _ = try S3Backend(location: location, transport: transport, pageLimit: 2)
                .boundedSubtreeListing(at: root, objectLimit: 100)
        }
    }
}
