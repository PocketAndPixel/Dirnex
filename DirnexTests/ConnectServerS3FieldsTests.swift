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

    private func account(of form: ConnectServerPrompt.Form?) -> S3Account? {
        guard case let .s3Account(account)? = form?.endpoint else { return nil }
        return account
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
        arguments: ["accessKeyID", "secretKey"]
    )
    func missingFieldIsRefused(blank: String) {
        let fields = fields()
        fields.region.stringValue = "us-east-1"
        fields.bucket.stringValue = "photos"
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

    /// The user's half of the same field, and the opposite answer: an S3-compatible endpoint is
    /// typed in full, so nothing is derived from the region and a blank one can stay blank — which
    /// is what the record then keeps. Resolving it here was what brought `us-east-1` back on every
    /// edit of a server whose regions are fiction (reported 2026-08-14).
    @Test("a blank region stays blank for an S3-compatible server")
    func blankRegionStaysBlankForCompatible() throws {
        let fields = fields()
        choose(1, in: fields.serviceControl)
        fields.endpoint.stringValue = "s3.lax.example.net"
        fields.region.stringValue = ""
        fields.bucket.stringValue = "photos"
        fields.accessKeyID.stringValue = "AKIAEXAMPLE"
        fields.secretKey.stringValue = "s3cret"

        let location = try #require(bucket(of: fields.readForm(saveName: nil)))
        #expect(location.region.isEmpty)
        #expect(location.host == "s3.lax.example.net")
        // And it still signs — the fallback lives at the signature, not in the record.
        #expect(location.signatureSpecifier == "aws:amz:us-east-1:s3")
    }

    /// The same for an account, since the two readers share one funnel and a rule applied to one of
    /// them would let the sheet and its bucket picker disagree about which connection this is.
    @Test("a blank region stays blank for a compatible account too")
    func blankRegionStaysBlankForCompatibleAccount() throws {
        let fields = fields()
        choose(1, in: fields.serviceControl)
        fields.endpoint.stringValue = "s3.lax.example.net"
        fields.region.stringValue = ""
        fields.accessKeyID.stringValue = "AKIAEXAMPLE"
        fields.secretKey.stringValue = "s3cret"

        #expect(try #require(fields.readAccount()).account.region.isEmpty)
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
}
