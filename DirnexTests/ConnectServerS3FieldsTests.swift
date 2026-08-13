import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The S3 half of the Connect-to-Server form builds one `S3Location` out of what the user typed,
/// and every field it gets wrong fails the same way: a signature computed for a host or a region
/// the server did not expect, reported as a refusal that names nothing the user can act on.
///
/// The assertions are over the *value produced*, never over a caption — the app test target
/// inherits whatever `AppleLanguages` the developer has Dirnex pinned to (docs/NOTES.md), so a test
/// resting on a label's words fails on the machine of anyone checking a translation.
@Suite("Connect sheet S3 fields")
@MainActor
struct ConnectServerS3FieldsTests {
    /// Build the field set inside a real grid, the way the form does — the rows have to exist
    /// before anything can be shown, hidden or read.
    private func fields() -> ConnectServerS3Fields {
        let fields = ConnectServerS3Fields()
        _ = fields.buildRows(in: NSGridView(views: [[NSGridCell.emptyContentView]]))
        return fields
    }

    /// Drive a popup the way AppKit does: `selectItem(at:)` alone changes the selection without
    /// sending the action, so a test built on it would prove nothing about the wiring.
    private func choose(_ index: Int, in popup: NSPopUpButton) {
        popup.selectItem(at: index)
        if let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
    }

    private func bucket(of form: ConnectServerPrompt.Form?) -> S3Location? {
        guard case let .s3(location)? = form?.endpoint else { return nil }
        return location
    }

    // MARK: - Amazon

    /// The reason Amazon has no endpoint field at all: the host *is* the region, and a bucket
    /// addressed through the wrong one answers 301 rather than serving it.
    @Test("an Amazon connection derives its host from the region")
    func amazonDerivesHost() throws {
        let fields = fields()
        fields.region.stringValue = "eu-central-1"
        fields.bucket.stringValue = "photos"
        fields.accessKeyID.stringValue = "AKIAEXAMPLE"
        fields.secretKey.stringValue = "s3cret"

        let location = try #require(bucket(of: fields.readForm(saveName: nil)))
        #expect(location.host == "s3.eu-central-1.amazonaws.com")
        #expect(location.region == "eu-central-1")
        #expect(location.bucket == "photos")
        #expect(location.addressing == .virtualHost)
        #expect(location.usesTLS)
        #expect(location.port == 443)
    }

    /// Path-style is a checkbox on the *compatible* rows, which are hidden for Amazon — so ticking
    /// it and then switching services must not leave virtual-host addressing behind.
    @Test("the path-style checkbox cannot leak into an Amazon connection")
    func amazonIgnoresPathStyle() throws {
        let fields = fields()
        fields.region.stringValue = "us-east-1"
        fields.bucket.stringValue = "photos"
        fields.accessKeyID.stringValue = "AKIAEXAMPLE"
        fields.secretKey.stringValue = "s3cret"
        fields.pathStyleCheckbox.state = .on

        #expect(try #require(bucket(of: fields.readForm(saveName: nil))).addressing == .virtualHost)
    }

    // MARK: - S3-compatible

    @Test("a compatible endpoint carries its own host, port and scheme")
    func compatibleParsesEndpoint() throws {
        let fields = fields()
        choose(1, in: fields.serviceControl)
        fields.endpoint.stringValue = "http://127.0.0.1:9000"
        fields.region.stringValue = "us-east-1"
        fields.bucket.stringValue = "dirnex"
        fields.accessKeyID.stringValue = "minioadmin"
        fields.secretKey.stringValue = "minioadmin"
        fields.pathStyleCheckbox.state = .on

        let location = try #require(bucket(of: fields.readForm(saveName: nil)))
        #expect(location.host == "127.0.0.1")
        #expect(location.port == 9000)
        #expect(!location.usesTLS)
        #expect(location.addressing == .path)
        #expect(location.bucketURL == "http://127.0.0.1:9000/dirnex/")
    }

    @Test("a compatible connection with an unusable endpoint is refused rather than guessed at")
    func compatibleRefusesBadEndpoint() {
        let fields = fields()
        choose(1, in: fields.serviceControl)
        fields.endpoint.stringValue = "minio.local:not-a-port"
        fields.region.stringValue = "us-east-1"
        fields.bucket.stringValue = "dirnex"
        fields.accessKeyID.stringValue = "minioadmin"
        fields.secretKey.stringValue = "minioadmin"

        #expect(fields.readForm(saveName: nil) == nil)
    }

    // MARK: - Required fields

    @Test(
        "every required field is required",
        arguments: ["bucket", "accessKeyID", "secretKey"]
    )
    func missingFieldIsRefused(blank: String) {
        let fields = fields()
        fields.region.stringValue = "us-east-1"
        fields.bucket.stringValue = blank == "bucket" ? "" : "photos"
        fields.accessKeyID.stringValue = blank == "accessKeyID" ? "" : "AKIAEXAMPLE"
        fields.secretKey.stringValue = blank == "secretKey" ? "" : "s3cret"

        #expect(fields.readForm(saveName: nil) == nil)
    }

    // MARK: - The region is the one field that is optional

    /// The field starts **empty** rather than prefilled, because a region is genuinely optional for
    /// most S3-compatible servers — measured 2026-08-13 against a real one, which verified the
    /// signature while ignoring the credential scope's region entirely. A prefilled value states a
    /// fact about the user's server that the app does not know; the placeholder says the same thing
    /// honestly.
    @Test("the region field starts empty")
    func regionStartsEmpty() {
        let fields = fields()
        #expect(fields.region.stringValue.isEmpty)
    }

    @Test("a blank region connects, signed for the default")
    func blankRegionUsesTheDefault() throws {
        let fields = fields()
        fields.region.stringValue = ""
        fields.bucket.stringValue = "photos"
        fields.accessKeyID.stringValue = "AKIAEXAMPLE"
        fields.secretKey.stringValue = "s3cret"

        let location = try #require(bucket(of: fields.readForm(saveName: nil)))
        #expect(location.region == "us-east-1")
        // SigV4 always names a region and — for the Amazon service — the *host* is derived from it,
        // so a blank field resolving to an empty region would address `s3..amazonaws.com`: not a
        // wrong server but no server. This is what stops that.
        #expect(location.host == "s3.us-east-1.amazonaws.com")
    }

    @Test("the bucket picker still asks with a blank region")
    func blankRegionStillListsBuckets() throws {
        // The half a fallback applied in `readForm` alone would miss: the picker's own guard rejects
        // an empty region, so it would sit refusing to ask on a form whose Connect button works.
        let fields = fields()
        fields.region.stringValue = ""
        fields.accessKeyID.stringValue = "AKIAEXAMPLE"
        fields.secretKey.stringValue = "s3cret"

        let account = try #require(fields.readAccount())
        #expect(account.account.region == "us-east-1")
    }

    /// A secret is not trimmed — it is 40 characters of base64 and every one of them counts — where
    /// the identifiers beside it are, since a pasted key id routinely arrives with a trailing space.
    @Test("identifiers are trimmed and the secret is not")
    func trimming() throws {
        let fields = fields()
        fields.region.stringValue = " us-east-1 "
        fields.bucket.stringValue = " photos "
        fields.accessKeyID.stringValue = " AKIAEXAMPLE "
        fields.secretKey.stringValue = " s3cret "

        let form = try #require(fields.readForm(saveName: nil))
        let location = try #require(bucket(of: form))
        #expect(location.region == "us-east-1")
        #expect(location.bucket == "photos")
        #expect(location.accessKeyID == "AKIAEXAMPLE")
        #expect(form.password == " s3cret ")
    }

    // MARK: - Prefill

    /// Editing a saved bucket must give back the same connection. The service is re-derived from
    /// the *host* rather than stored beside it, which is what keeps the two from disagreeing — so
    /// the round-trip is the assertion that derivation is right.
    @Test(
        "a saved connection round-trips through the form",
        arguments: [
            S3Location(
                host: "s3.eu-central-1.amazonaws.com",
                bucket: "photos",
                region: "eu-central-1",
                accessKeyID: "AKIAEXAMPLE"
            ),
            S3Location(
                host: "127.0.0.1",
                port: 9000,
                bucket: "dirnex",
                region: "us-east-1",
                accessKeyID: "minioadmin",
                addressing: .path,
                usesTLS: false
            ),
            S3Location(
                host: "abc123.r2.cloudflarestorage.com",
                bucket: "media",
                region: "auto",
                accessKeyID: "R2KEY"
            )
        ]
    )
    func prefillRoundTrips(saved: S3Location) throws {
        let fields = fields()
        fields.apply(location: saved)
        // `apply` reads the secret from the Keychain, which holds nothing in a test — and a blank
        // secret is refused, so it is supplied here rather than left to make every case fail for
        // the same uninteresting reason.
        fields.secretKey.stringValue = "s3cret"

        #expect(try #require(bucket(of: fields.readForm(saveName: nil))) == saved)
    }

    // MARK: - The account the bucket picker asks

    /// The whole point of the picker: it has to work *before* the field it fills is filled in.
    @Test("an account reads with the bucket field empty")
    func accountNeedsNoBucket() throws {
        let fields = fields()
        fields.region.stringValue = "eu-central-1"
        fields.accessKeyID.stringValue = "AKIAEXAMPLE"
        fields.secretKey.stringValue = "s3cret"
        fields.bucket.stringValue = ""

        let resolved = try #require(fields.readAccount())
        #expect(resolved.account.host == "s3.eu-central-1.amazonaws.com")
        #expect(resolved.account.region == "eu-central-1")
        #expect(resolved.account.accessKeyID == "AKIAEXAMPLE")
        #expect(resolved.secretAccessKey == "s3cret")
        // And the form itself still refuses to connect without one, so the two questions stay
        // separate rather than the picker quietly loosening what Connect accepts.
        #expect(fields.readForm(saveName: nil) == nil)
    }

    @Test("an account takes the typed endpoint for an S3-compatible server")
    func accountUsesTheTypedEndpoint() throws {
        let fields = fields()
        choose(1, in: fields.serviceControl)
        fields.endpoint.stringValue = "http://127.0.0.1:9000"
        fields.region.stringValue = "us-east-1"
        fields.accessKeyID.stringValue = "minioadmin"
        fields.secretKey.stringValue = "minioadmin"

        let account = try #require(fields.readAccount()).account
        #expect(account.host == "127.0.0.1")
        #expect(account.port == 9000)
        #expect(account.usesTLS == false)
        // Path-style or not, a service request never names a bucket — so the addressing mode the
        // form carries has nowhere to go, which is exactly why `S3Account` does not hold one.
        // Asserted through the arguments rather than the URL property, which is internal to the
        // core: this is what actually reaches `curl`, so it is the stronger claim anyway.
        #expect(S3ProcessArguments.listBuckets(account: account).last == "http://127.0.0.1:9000/")
    }

    /// The credentials are required and the region is not — it resolves to
    /// ``ConnectServerS3Fields/defaultRegion`` when blank, which `blankRegionStillListsBuckets`
    /// covers from the other side.
    @Test("no account without a secret or an access key")
    func accountNeedsTheRest() {
        let missingSecret = fields()
        missingSecret.region.stringValue = "us-east-1"
        missingSecret.accessKeyID.stringValue = "AKIAEXAMPLE"
        #expect(missingSecret.readAccount() == nil)

        let missingKey = fields()
        missingKey.region.stringValue = "us-east-1"
        missingKey.secretKey.stringValue = "s3cret"
        #expect(missingKey.readAccount() == nil)
    }
}
