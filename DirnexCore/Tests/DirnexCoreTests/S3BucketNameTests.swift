import Foundation
import Testing

@testable import DirnexCore

/// The bucket-name rules (PLAN.md §M21).
///
/// The five names in `refusesWhatARealServerRefuses` are **the exact names a real S3-compatible
/// endpoint refused** on 2026-08-13, and they are the reason this validator exists rather than a
/// nicety on top of the server's own answer: every one of them came back as the same
/// `400 InvalidBucketName` — "The specified bucket is not valid" — so the server distinguishes none
/// of the five and the user learns nothing. What is pinned here is the *distinguishing*.
@Suite("S3 bucket names")
struct S3BucketNameTests {
    @Test("an ordinary name is accepted")
    func acceptsAnOrdinaryName() {
        #expect(S3BucketName.problem(with: "dirnex-probe-a") == nil)
        #expect(S3BucketName.isValid("my-bucket-2026"))
        #expect(S3BucketName.isValid("abc"))
    }

    @Test("refuses what a real server refuses, and says which rule broke")
    func refusesWhatARealServerRefuses() {
        // Every one of these was sent to a live endpoint and answered 400 InvalidBucketName.
        #expect(S3BucketName.problem(with: "Dirnex-Probe-Upper") == .invalidCharacter)
        #expect(S3BucketName.problem(with: "ab") == .tooShort)
        #expect(S3BucketName.problem(with: "dirnex_probe_underscore") == .invalidCharacter)
        #expect(S3BucketName.problem(with: "192.168.1.50") == .addressFormatted)
        #expect(S3BucketName.problem(with: String(repeating: "a", count: 64)) == .tooLong)
    }

    @Test("the length boundaries are inclusive on both sides")
    func lengthBoundariesAreInclusive() {
        #expect(S3BucketName.problem(with: String(repeating: "a", count: 3)) == nil)
        #expect(S3BucketName.problem(with: String(repeating: "a", count: 63)) == nil)
        #expect(S3BucketName.problem(with: String(repeating: "a", count: 2)) == .tooShort)
        #expect(S3BucketName.problem(with: String(repeating: "a", count: 64)) == .tooLong)
    }

    @Test("edges must be alphanumeric")
    func edgesMustBeAlphanumeric() {
        #expect(S3BucketName.problem(with: "-leading") == .badEdge)
        #expect(S3BucketName.problem(with: "trailing-") == .badEdge)
        #expect(S3BucketName.problem(with: ".dotted") == .badEdge)
        #expect(S3BucketName.problem(with: "dotted.") == .badEdge)
        // A name of nothing but hyphens has no alphanumeric edge to find, and must not be read as
        // empty by a trim-based check.
        #expect(S3BucketName.problem(with: "---") == .badEdge)
    }

    @Test("consecutive dots are refused where one dot is fine")
    func consecutiveDotsAreRefused() {
        #expect(S3BucketName.problem(with: "my.bucket") == nil)
        #expect(S3BucketName.problem(with: "my..bucket") == .consecutiveDots)
    }

    /// The IPv4 rule is exactly four decimal octets. Anything else is an ordinary name, and reading
    /// it as an address would refuse names people genuinely use.
    @Test("only a real four-octet address is address-formatted")
    func onlyFourOctetsCountAsAnAddress() {
        #expect(S3BucketName.problem(with: "192.168.1.50") == .addressFormatted)
        #expect(S3BucketName.problem(with: "10.0.0.1") == .addressFormatted)
        #expect(S3BucketName.problem(with: "192.168.1.50.backup") == nil)
        #expect(S3BucketName.problem(with: "192.168.1") == nil)
        #expect(S3BucketName.problem(with: "999.999.999.999") == nil)
        #expect(S3BucketName.problem(with: "1.2.3.4x") == nil)
    }

    @Test("the reserved prefixes and suffixes are refused")
    func reservedAffixesAreRefused() {
        #expect(S3BucketName.problem(with: "xn--puny-code") == .reservedPrefix)
        #expect(S3BucketName.problem(with: "sthree-internal") == .reservedPrefix)
        #expect(S3BucketName.problem(with: "my-bucket-s3alias") == .reservedSuffix)
        #expect(S3BucketName.problem(with: "my-bucket--ol-s3") == .reservedSuffix)
    }

    /// A dotted name is **legal** — it was accepted by the same live endpoint that refused the five
    /// above — and it is nonetheless the one that strands a user over TLS, because a wildcard
    /// certificate is one label deep. That is an *addressing* problem, not a naming one, so it is
    /// recovered by the path-style retry (`PanelViewController+ConnectS3`) and must never be
    /// refused here.
    @Test("a dot is legal, whatever it costs the connection")
    func aDotIsLegal() {
        #expect(S3BucketName.problem(with: "dirnex.probe.dotted") == nil)
    }
}
