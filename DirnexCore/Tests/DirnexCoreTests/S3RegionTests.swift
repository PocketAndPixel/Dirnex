import Foundation
import Testing

@testable import DirnexCore

/// An S3 connection with **no region**, which is the honest record for a server whose regions are
/// fiction (measured — see ``S3Region``).
///
/// The rule it encodes is a split: the blank is *preserved* everywhere the connection is recorded —
/// descriptor, backend id, Keychain key, sidebar tooltip — and *resolved* only at the moment a
/// request is signed. Before 2026-08-14 the resolution happened in the connect form instead, so the
/// fallback was what got saved: clearing the field and pressing Connect brought `us-east-1` back on
/// the next edit, which reads as the app ignoring what was typed (reported by a user, twice).
@Suite("S3 with no region")
struct S3RegionTests {
    private let account = S3Account(
        host: "s3.lax.example.net",
        region: "",
        accessKeyID: "AKIAEXAMPLE",
        addressing: .path
    )

    // MARK: - Signing

    /// SigV4 always names a region, so the one thing the blank may never reach is the credential
    /// scope: `aws:amz::s3` is a signature no server computes the same way.
    @Test("an unstated region still signs, with the fallback")
    func unstatedRegionSigns() {
        #expect(account.signatureSpecifier == "aws:amz:us-east-1:s3")
        #expect(account.bucketLocation(named: "photos").signatureSpecifier == "aws:amz:us-east-1:s3")
    }

    @Test("a stated region signs with itself")
    func statedRegionSigns() {
        let stated = S3Account(
            host: "s3.eu-central-1.amazonaws.com",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )

        #expect(stated.signatureSpecifier == "aws:amz:eu-central-1:s3")
    }

    // MARK: - Identity

    /// The descriptor is the backend id and the Keychain key, so a record that cannot round-trip is
    /// a sidebar row that cannot be opened. The empty region segment has to survive both ways.
    @Test("an account with no region round-trips through its descriptor")
    func accountDescriptorRoundTrips() throws {
        let restored = try #require(S3Account(descriptor: account.descriptor))

        #expect(restored == account)
        #expect(restored.region.isEmpty)
    }

    @Test("a bucket with no region round-trips through its descriptor")
    func bucketDescriptorRoundTrips() throws {
        let bucket = account.bucketLocation(named: "photos")
        let restored = try #require(S3Location(descriptor: bucket.descriptor))

        #expect(restored == bucket)
        #expect(restored.bucket == "photos")
        #expect(restored.region.isEmpty)
    }

    /// The fields that are not optional stay that way — a descriptor missing the *key* or the *host*
    /// addresses nothing, and relaxing the region's guard must not relax theirs.
    @Test("a descriptor with no key or no host is still refused", arguments: [
        "s3ap://@s3.lax.example.net:443/us-east-1",
        "s3ap://AKIAEXAMPLE@:443/us-east-1"
    ])
    func malformedDescriptorsStillRefused(descriptor: String) {
        #expect(S3Account(descriptor: descriptor) == nil)
    }

    // MARK: - What the user sees

    /// `host ()` would be the app inventing the very fact the record declines to keep.
    @Test("the sidebar address omits a region there is none of")
    func addressOmitsAnUnstatedRegion() {
        let saved = ServerConnection(name: "S3", endpoint: .s3Account(account))
        let bucket = ServerConnection(
            name: "Bucket",
            endpoint: .s3(account.bucketLocation(named: "photos"))
        )

        #expect(saved.address == "s3.lax.example.net")
        #expect(bucket.address == "photos — s3.lax.example.net")
    }

    // MARK: - Creating a bucket

    /// A `<LocationConstraint>` tells the service **where to put the bucket**, which is exactly what
    /// a user who left the field blank did not say. Same no-body path as `us-east-1`, for a
    /// different reason: that one is AWS's own rule about its default region.
    @Test("creating a bucket with no region sends no location constraint")
    func createBucketSendsNoConstraint() {
        #expect(S3ProcessArguments.createBucketBody(region: "") == nil)
        #expect(S3ProcessArguments.createBucketBody(region: "us-east-1") == nil)
        #expect(S3ProcessArguments.createBucketBody(region: "eu-central-1")?
            .contains("<LocationConstraint>eu-central-1</LocationConstraint>") == true)
    }
}
