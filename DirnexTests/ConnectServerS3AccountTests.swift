import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The Connect sheet's S3 **account** half: what a blank bucket field means, and what a saved
/// account gives back (PLAN.md §M21 Slice 9).
///
/// Its own suite because `ConnectServerS3FieldsTests` reached SwiftLint's `type_body_length` when
/// this arrived, and because it is the concept boundary: everything here is about the one field
/// that may be left out and the *place* leaving it out reaches. The bucket suite keeps the rest.
///
/// The assertions are over the value produced, never over a caption — the app test target inherits
/// whatever `AppleLanguages` the developer has Dirnex pinned to (docs/NOTES.md).
@Suite("Connect sheet S3 accounts")
@MainActor
struct ConnectServerS3AccountTests {
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

    // MARK: - The bucket is the one field that may be left out

    /// A blank bucket is an *answer*, not an omission: it connects to the account and browses its
    /// buckets as rows (PLAN.md §M21 Slice 9). Everything else the connection needs is still
    /// required — `missingFieldIsRefused`, in the bucket suite, pins that from the other side.
    @Test("a blank bucket reads as the account")
    func blankBucketReadsAsTheAccount() throws {
        let fields = fields()
        fields.region.stringValue = "eu-central-1"
        fields.bucket.stringValue = ""
        fields.accessKeyID.stringValue = "AKIAEXAMPLE"
        fields.secretKey.stringValue = "s3cret"

        let form = try #require(fields.readForm(saveName: nil))
        let account = try #require(self.account(of: form))
        #expect(account.host == "s3.eu-central-1.amazonaws.com")
        #expect(account.region == "eu-central-1")
        #expect(account.accessKeyID == "AKIAEXAMPLE")
        #expect(form.password == "s3cret")
        // And it is not a bucket connection with an empty bucket, which is the failure that would
        // read as "connected" and address `https://.s3.eu-central-1.amazonaws.com/`.
        #expect(bucket(of: form) == nil)
    }

    /// The addressing mode has to reach the account, not just the bucket. It looked decorative
    /// while `ListAllMyBuckets` was the only thing an account did — a service request names no
    /// bucket — and it stopped being decorative the moment an account became a place: every bucket
    /// reached from it, plus F7's `CreateBucket` and F8's `DeleteBucket`, spell one into the URL.
    @Test("a path-style account carries path-style addressing to its buckets")
    func accountCarriesAddressing() throws {
        let fields = fields()
        choose(1, in: fields.serviceControl)
        fields.endpoint.stringValue = "http://127.0.0.1:9000"
        fields.region.stringValue = "us-east-1"
        fields.bucket.stringValue = ""
        fields.accessKeyID.stringValue = "minioadmin"
        fields.secretKey.stringValue = "minioadmin"
        fields.pathStyleCheckbox.state = .on

        let account = try #require(self.account(of: fields.readForm(saveName: nil)))
        #expect(account.addressing == .path)
        #expect(account.bucketLocation(named: "dirnex").bucketURL
            == "http://127.0.0.1:9000/dirnex/")
    }

    /// The path-style row is hidden for Amazon, so ticking it and switching services must not leave
    /// it on the account either — the same leak `amazonIgnoresPathStyle` rules out for a bucket.
    @Test("the path-style checkbox cannot leak into an Amazon account")
    func amazonAccountIgnoresPathStyle() throws {
        let fields = fields()
        fields.region.stringValue = "us-east-1"
        fields.accessKeyID.stringValue = "AKIAEXAMPLE"
        fields.secretKey.stringValue = "s3cret"
        fields.pathStyleCheckbox.state = .on

        #expect(try #require(account(of: fields.readForm(saveName: nil))).addressing == .virtualHost)
    }

    /// A whitespace-only bucket is the same answer as a blank one — the field is trimmed, so a
    /// stray space cannot be the difference between connecting to a bucket and connecting to the
    /// account.
    @Test("a bucket of nothing but spaces is still the account")
    func whitespaceBucketReadsAsTheAccount() throws {
        let fields = fields()
        fields.region.stringValue = "us-east-1"
        fields.bucket.stringValue = "   "
        fields.accessKeyID.stringValue = "AKIAEXAMPLE"
        fields.secretKey.stringValue = "s3cret"

        #expect(account(of: fields.readForm(saveName: nil)) != nil)
    }

    /// A saved **account** has to come back as one. The failure this rules out is quiet and
    /// specific: a prefill that left the bucket field holding anything at all would turn an account
    /// the user saved into a bucket connection on the next Connect, silently — and the account is
    /// exactly the connection whose bucket field is meant to be empty.
    @Test(
        "a saved account round-trips through the form",
        arguments: [
            S3Account(
                host: "s3.eu-central-1.amazonaws.com",
                region: "eu-central-1",
                accessKeyID: "AKIAEXAMPLE"
            ),
            S3Account(
                host: "127.0.0.1",
                port: 9000,
                region: "us-east-1",
                accessKeyID: "minioadmin",
                addressing: .path,
                usesTLS: false
            )
        ]
    )
    func accountPrefillRoundTrips(saved: S3Account) throws {
        let fields = fields()
        fields.apply(account: saved)
        fields.secretKey.stringValue = "s3cret"

        #expect(fields.bucket.stringValue.isEmpty)
        #expect(try #require(account(of: fields.readForm(saveName: nil))) == saved)
    }

    /// The two prefills share one funnel, so this is really about the funnel being *reset*: editing
    /// an account after a bucket must not leave the bucket's name in the field, which would connect
    /// somewhere the saved record never named.
    @Test("prefilling an account clears a bucket left over from a previous prefill")
    func accountPrefillClearsTheBucket() throws {
        let fields = fields()
        fields.apply(location: S3Location(
            host: "s3.us-east-1.amazonaws.com",
            bucket: "photos",
            region: "us-east-1",
            accessKeyID: "AKIAEXAMPLE"
        ))
        fields.apply(account: S3Account(
            host: "s3.us-east-1.amazonaws.com",
            region: "us-east-1",
            accessKeyID: "AKIAEXAMPLE"
        ))
        fields.secretKey.stringValue = "s3cret"

        #expect(account(of: fields.readForm(saveName: nil)) != nil)
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
        // The form reads the same account out of the same fields — which is the point of them
        // sharing one funnel. Until Slice 9 this asserted the opposite (Connect refused a blank
        // bucket), and the two claims are the same claim: what the picker asks and what a blank
        // bucket connects to must be one account, or the button would offer buckets from somewhere
        // other than the place Connect would land.
        #expect(account(of: fields.readForm(saveName: nil)) == resolved.account)
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

    /// The credentials are required and the region is not — a blank one is kept blank for an
    /// S3-compatible endpoint and resolved only for Amazon, which `blankRegionStillListsBuckets`
    /// and `blankRegionStaysBlankForCompatible` cover from the other side.
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
