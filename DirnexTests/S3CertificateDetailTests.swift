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

    // MARK: - Correcting the addressing instead of reporting it

    private func request(
        addressing: S3Addressing,
        corrected: Bool = false
    ) -> PanelViewController.S3ConnectRequest {
        PanelViewController.S3ConnectRequest(
            location: location(addressing: addressing),
            secretAccessKey: "shhh",
            saveName: nil,
            activityName: nil,
            savedServerName: "Sharktech",
            hasCorrectedRegion: true,
            hasCorrectedAddressing: corrected
        )
    }

    /// The recovery the wording above exists to *avoid needing*: the endpoint is reachable path-style
    /// with its certificate fully verified (measured against the real server), so the connect retries
    /// rather than handing the user a sentence about a checkbox.
    @Test("a virtual-host TLS failure is retried path-style")
    func virtualHostFailureIsCorrected() throws {
        let retry = try #require(PanelViewController.addressingCorrection(
            for: S3ResponseError.transport(.certificateNotTrusted),
            request: request(addressing: .virtualHost)
        ))
        #expect(retry.location.addressing == .path)
        #expect(retry.hasCorrectedAddressing)
        // Everything else survives, and each of these is load-bearing: a dropped `savedServerName`
        // loses the correction on the way to the store, a dropped `hasCorrectedRegion` re-opens the
        // region loop it was set to close, and a dropped bucket or key connects somewhere else.
        #expect(retry.location.bucket == "photos")
        #expect(retry.location.host == "s3.lax.sharktech.net")
        #expect(retry.location.accessKeyID == "AKIAEXAMPLE")
        #expect(retry.savedServerName == "Sharktech")
        #expect(retry.hasCorrectedRegion)
        #expect(retry.secretAccessKey == "shhh")
    }

    /// Under path-style there is no bucket in the host, so exit 60 is the endpoint's own certificate
    /// and there is nothing to re-address — this is the branch that must report instead of retrying,
    /// and it is what makes the retry a *measurement* of which failure it was.
    @Test("a path-style TLS failure is not retried")
    func pathStyleFailureIsReported() {
        #expect(PanelViewController.addressingCorrection(
            for: S3ResponseError.transport(.certificateNotTrusted),
            request: request(addressing: .path)
        ) == nil)
    }

    @Test("one correction per connect")
    func correctionHappensOnce() {
        // The retry goes back through `connectS3`, so without this an endpoint that keeps failing
        // verification would re-address forever.
        #expect(PanelViewController.addressingCorrection(
            for: S3ResponseError.transport(.certificateNotTrusted),
            request: request(addressing: .virtualHost, corrected: true)
        ) == nil)
    }

    /// Only exit 60 is about the host *name*. An unresolvable host or a timeout says nothing about
    /// addressing, and a refusal the service explained has already been answered by `handleS3Refusal`
    /// — re-addressing any of them would swap the connection out from under a correct diagnosis.
    @Test("only a certificate failure is re-addressed")
    func otherFailuresAreNotCorrected() {
        let virtualHost = request(addressing: .virtualHost)
        for failure: S3TransportFailure in [.couldNotResolveHost, .operationTimedOut, .other] {
            #expect(PanelViewController.addressingCorrection(
                for: S3ResponseError.transport(failure),
                request: virtualHost
            ) == nil)
        }
        #expect(PanelViewController.addressingCorrection(
            for: S3ResponseError.service(
                S3ServiceError(status: 403, code: "AccessDenied", message: "")
            ),
            request: virtualHost
        ) == nil)
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
