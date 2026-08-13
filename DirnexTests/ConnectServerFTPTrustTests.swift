import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The FTPS certificate pin surviving an edit.
///
/// It is the one thing a saved server holds that the form has **no row for** — trust is answered in
/// a dialog, not typed — so it is the one field a prefill-then-read round trip can silently drop,
/// and it did: `applyPrefill` matched `.ftp(location, authentication, _)` and `readForm` rebuilt the
/// endpoint with the pin defaulted to `nil`, so *any* edit of an FTPS server erased the certificate
/// the user had trusted. Nothing reports it — the next connect simply asks the question again, which
/// reads as the app being forgetful rather than as an edit having thrown something away.
///
/// Everything else each protocol stores is a field with a control behind it, so `ConnectServerS3*`'s
/// round-trip suites and this one together cover "an edit keeps every field".
@Suite("Connect sheet FTPS trust")
@MainActor
struct ConnectServerFTPTrustTests {
    private static let pin = "sha256//Aq7DJ0mE+mB9y8xIFxvfCkPzc/M2z2LFYBhYxpZmyGw="

    private func fields() -> ConnectServerFTPFields {
        let fields = ConnectServerFTPFields()
        _ = fields.buildRows(in: NSGridView(views: [[NSGridCell.emptyContentView]]))
        return fields
    }

    private func location(
        host: String = "nas.local",
        security: FTPSecurity = .explicit
    ) -> FTPLocation {
        FTPLocation(host: host, port: 21, username: "oleg", security: security)
    }

    private func trust(of form: ConnectServerPrompt.Form?) -> String? {
        guard case let .ftp(_, _, trustedPublicKey)? = form?.endpoint else { return nil }
        return trustedPublicKey
    }

    /// The bug, from the direction a user meets it: open Edit… on a pinned FTPS server, change
    /// nothing that identifies it, press Connect — the pin must still be there.
    @Test("an edit that keeps the server keeps its trusted certificate")
    func editKeepsThePin() {
        let fields = fields()
        fields.apply(
            location: location(),
            authentication: .password,
            trustedPublicKey: Self.pin
        )
        fields.password.stringValue = "hunter2"

        #expect(trust(of: fields.readForm(saveName: "NAS")) == Self.pin)
    }

    /// Editing the credentials is the common edit, and the username is *part of* the `FTPLocation`
    /// the pin was filed against — so a naive equality check would drop the pin on exactly the edit
    /// people make most, while nothing about the certificate has changed.
    @Test("changing the credentials keeps the pin — a certificate is not a login")
    func credentialEditKeepsThePin() {
        let fields = fields()
        fields.apply(location: location(), authentication: .password, trustedPublicKey: Self.pin)
        fields.user.stringValue = "someone-else"
        fields.password.stringValue = "hunter2"

        #expect(trust(of: fields.readForm(saveName: "NAS")) == Self.pin)
    }

    /// The other half, and the reason the pin is carried with its location rather than on its own: a
    /// pin answers "this certificate, from this server". Re-point the record and the old answer is
    /// not merely stale, it is about somewhere else — and carrying it over would present the new
    /// server's perfectly ordinary certificate as a *changed* one, which is the alarm that has to
    /// keep meaning something.
    @Test(
        "re-pointing the record at another server drops the pin",
        arguments: [
            FTPLocation(host: "other.local", port: 21, username: "oleg", security: .explicit),
            FTPLocation(host: "nas.local", port: 990, username: "oleg", security: .explicit),
            FTPLocation(host: "nas.local", port: 21, username: "oleg", security: .plain)
        ]
    )
    func changingTheServerDropsThePin(edited: FTPLocation) {
        let fields = fields()
        fields.apply(location: location(), authentication: .password, trustedPublicKey: Self.pin)
        fields.apply(location: edited, authentication: .password, trustedPublicKey: nil)
        fields.password.stringValue = "hunter2"

        #expect(trust(of: fields.readForm(saveName: "NAS")) == nil)
    }

    /// A server that was never pinned must not acquire one, which is what a stale field left over
    /// from a previous prefill would do — the same "the funnel has to be reset" claim the S3 suite
    /// makes about a bucket name.
    @Test("prefilling an unpinned server clears a pin left over from a previous prefill")
    func prefillClearsAStalePin() {
        let fields = fields()
        fields.apply(location: location(), authentication: .password, trustedPublicKey: Self.pin)
        fields.apply(location: location(), authentication: .password, trustedPublicKey: nil)
        fields.password.stringValue = "hunter2"

        #expect(trust(of: fields.readForm(saveName: "NAS")) == nil)
    }
}
