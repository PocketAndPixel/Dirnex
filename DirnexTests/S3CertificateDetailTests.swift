import DirnexCore
import Testing

@testable import Dirnex

/// What the connect sheet says when TLS verification fails — two different failures that arrive as
/// one `curl` exit code, and which one it is depends on the **addressing mode**, not on the server.
///
/// Under virtual-host addressing the name being verified is `<bucket>.<host>`, not the endpoint the
/// user typed, and a wildcard certificate is only one label deep (RFC 6125). Measured live
/// 2026-08-13 against a real S3-compatible endpoint whose `*.lax.sharktech.net` certificate is
/// valid, publicly issued, and cannot cover `dirnex-test.s3.lax.sharktech.net`: the connect failed
/// at exit 60 and the sheet advised reaching the server over **plaintext http://** — an addressing
/// problem diagnosed as a trust problem, with the one remedy nobody should be nudged toward. The
/// path-style checkbox two rows above the message was the actual fix.
@Suite("S3 certificate failure wording")
@MainActor
struct S3CertificateDetailTests {
    private func location(addressing: S3Addressing, bucket: String = "photos") -> S3Location {
        S3Location(
            host: "s3.lax.sharktech.net",
            bucket: bucket,
            region: "us-east-1",
            accessKeyID: "AKIAEXAMPLE",
            addressing: addressing,
            usesTLS: true
        )
    }

    @Test("virtual-host addressing points at the path-style checkbox, not at http://")
    func virtualHostNamesTheCheckbox() {
        let detail = PanelViewController.s3CertificateDetail(
            location: location(addressing: .virtualHost)
        )
        // The name that actually failed verification, which is not the endpoint the user typed.
        #expect(detail.contains("photos.s3.lax.sharktech.net"))
        // Named by interpolating the checkbox's own title, so the sentence and the control cannot
        // drift apart — and so it reads correctly in all fourteen languages.
        #expect(detail.contains(ConnectText.pathStyle))
        // The regression this exists to prevent: never advise plaintext for this case.
        #expect(!detail.contains("http://"))
    }

    @Test("path-style addressing keeps the trust wording")
    func pathStyleKeepsTrustWording() {
        // The other half, and the reason the branch is on addressing rather than on the service
        // picker: with the bucket in the path, the name verified *is* the endpoint, so a failure
        // here really is about trust and the old sentence is the right one.
        let detail = PanelViewController.s3CertificateDetail(location: location(addressing: .path))
        #expect(detail.contains("http://"))
        #expect(!detail.contains(ConnectText.pathStyle))
    }

    @Test("the bucket that failed is the one named")
    func namesTheRealBucket() {
        let detail = PanelViewController.s3CertificateDetail(
            location: location(addressing: .virtualHost, bucket: "my.dotted.bucket")
        )
        // A dotted bucket is why this is keyed on addressing rather than on "is this AWS": AWS's own
        // `*.s3.<region>.amazonaws.com` is one label deep too, so this state is reachable there and
        // path-style is the same answer.
        #expect(detail.contains("my.dotted.bucket.s3.lax.sharktech.net"))
    }

    /// A translation that drops a placeholder silently swallows the argument it was naming — here
    /// either the failing host or the name of the control the user is being sent to. Counting them
    /// is the assertion docs/NOTES.md ▸ Localization asks for, and it is checked against the
    /// **running** language rather than against English, so it holds whatever `AppleLanguages` the
    /// machine running the suite is pinned to.
    @Test("both interpolations survive into the rendered sentence")
    func bothArgumentsRender() {
        let detail = PanelViewController.s3CertificateDetail(
            location: location(addressing: .virtualHost)
        )
        #expect(!detail.contains("%@"))
        #expect(!detail.contains("%1$@"))
        #expect(!detail.contains("%2$@"))
    }
}
