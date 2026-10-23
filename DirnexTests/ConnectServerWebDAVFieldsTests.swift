import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The connect sheet's WebDAV rows (PLAN.md §M32 Slice 3): a URL pasted into the Host field, the
/// public share, and the two settled values an edit must carry because no row holds them.
@Suite("Connect sheet WebDAV fields")
@MainActor
struct ConnectServerWebDAVFieldsTests {
    private static let pin = "sha256//Aq7DJ0mE+mB9y8xIFxvfCkPzc/M2z2LFYBhYxpZmyGw="
    private static let nas = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")

    private func fields() -> ConnectServerWebDAVFields {
        let fields = ConnectServerWebDAVFields()
        _ = fields.buildRows(in: NSGridView(views: [[NSGridCell.emptyContentView]]))
        fields.setHidden(false)
        return fields
    }

    /// What a read form's WebDAV endpoint holds.
    private struct Read {
        let location: WebDAVLocation
        let scheme: WebDAVAuthScheme?
        let pin: String?
    }

    private func endpoint(of form: ConnectServerPrompt.Form?) -> Read? {
        guard case let .webdav(location, scheme, pin)? = form?.endpoint else { return nil }
        return Read(location: location, scheme: scheme, pin: pin)
    }

    @Test("an account reads back as the location typed, HTTPS by default")
    func readsAnAccount() throws {
        let fields = fields()
        fields.host.stringValue = "nas"
        fields.port.stringValue = "5006"
        fields.user.stringValue = "dirnex-test"
        fields.password.stringValue = "hunter2"

        let form = fields.readForm(saveName: "NAS")
        let read = try #require(endpoint(of: form))
        #expect(read.location == Self.nas)
        #expect(form?.password == "hunter2")
        #expect(form?.saveName == "NAS")
    }

    /// Nextcloud hands its users a URL, and pressing Connect with it still in the Host field has to
    /// connect to what it says rather than to a host called `https`.
    @Test("a URL left in the Host field is spread over the other fields on Connect")
    func urlIsSpread() throws {
        let fields = fields()
        fields.host.stringValue = "http://me%40example.com@cloud.example.com:8080"
            + "/remote.php/dav/files/me%40example.com/"
        fields.password.stringValue = "pw"

        let read = try #require(endpoint(of: fields.readForm(saveName: nil)))
        #expect(read.location == WebDAVLocation(
            host: "cloud.example.com",
            port: 8080,
            username: "me@example.com",
            usesTLS: false,
            rootPath: "/remote.php/dav/files/me@example.com"
        ))
        // And the fields say so, so what is on screen is what was dialed.
        #expect(fields.host.stringValue == "cloud.example.com")
        #expect(fields.port.stringValue == "8080")
        #expect(fields.securityControl.indexOfSelectedItem == 1)
        #expect(fields.path.stringValue == "/remote.php/dav/files/me@example.com")
    }

    @Test("a scheme without a port resets the port to that scheme's default")
    func schemeSetsDefaultPort() throws {
        let fields = fields()
        fields.port.stringValue = "5006"
        fields.host.stringValue = "http://nas"
        #expect(fields.spreadAddress())
        #expect(fields.port.stringValue == "80")
    }

    @Test("host:port moves the port and keeps the scheme the user chose")
    func hostAndPortKeepTheScheme() throws {
        let fields = fields()
        fields.securityControl.selectItem(at: 1)
        fields.host.stringValue = "nas:5005"
        #expect(fields.spreadAddress())
        #expect(fields.host.stringValue == "nas")
        #expect(fields.port.stringValue == "5005")
        #expect(fields.securityControl.indexOfSelectedItem == 1)
    }

    @Test("switching the scheme moves a default port and leaves a typed one")
    func securityRetargetsOnlyADefaultPort() {
        let fields = fields()
        #expect(fields.port.stringValue == "443")
        fields.securityControl.selectItem(at: 1)
        fields.securityControl.sendAction(
            fields.securityControl.action,
            to: fields.securityControl.target
        )
        #expect(fields.port.stringValue == "80")

        fields.port.stringValue = "5005"
        fields.securityControl.selectItem(at: 0)
        fields.securityControl.sendAction(
            fields.securityControl.action,
            to: fields.securityControl.target
        )
        #expect(fields.port.stringValue == "5005")
    }

    @Test("a blank user is a public share, with no password to send")
    func publicShare() throws {
        let fields = fields()
        fields.host.stringValue = "public.example.com"
        fields.password.stringValue = "ignored"
        let form = fields.readForm(saveName: nil)
        let read = try #require(endpoint(of: form))
        #expect(!read.location.hasCredentials)
        #expect(form?.password == nil)
    }

    @Test("what cannot be connected to is refused rather than sent")
    func refusals() {
        let fields = fields()
        #expect(fields.readForm(saveName: nil) == nil) // no host
        fields.host.stringValue = "ftp://nas"
        #expect(fields.readForm(saveName: nil) == nil) // not a WebDAV scheme
        fields.host.stringValue = "nas"
        fields.user.stringValue = "dirnex-test"
        #expect(fields.readForm(saveName: nil) == nil) // an account with no password
        fields.password.stringValue = "pw"
        fields.port.stringValue = "70000"
        #expect(fields.readForm(saveName: nil) == nil) // no such port
    }

    // MARK: - What an edit carries

    @Test("an edit that keeps the server keeps its scheme and its pin, whatever the user and root")
    func editKeepsSettledValues() throws {
        let fields = fields()
        fields.apply(location: Self.nas, authentication: .digest, trustedPublicKey: Self.pin)
        fields.user.stringValue = "someone-else"
        fields.path.stringValue = "/home"
        fields.password.stringValue = "pw"

        let read = try #require(endpoint(of: fields.readForm(saveName: "NAS")))
        #expect(read.scheme == .digest)
        #expect(read.pin == Self.pin)
    }

    @Test(
        "re-pointing the record at another server drops both",
        arguments: [("other", 5006, 0), ("nas", 5007, 0), ("nas", 5006, 1)]
    )
    func repointingDropsSettledValues(host: String, port: Int, security: Int) throws {
        let fields = fields()
        fields.apply(location: Self.nas, authentication: .basic, trustedPublicKey: Self.pin)
        fields.host.stringValue = host
        fields.port.stringValue = String(port)
        fields.securityControl.selectItem(at: security)
        fields.password.stringValue = "pw"

        let read = try #require(endpoint(of: fields.readForm(saveName: "NAS")))
        #expect(read.scheme == nil)
        #expect(read.pin == nil)
    }

    @Test("an account turned into a public share keeps its pin and sends no scheme")
    func publicShareDropsTheScheme() throws {
        let fields = fields()
        fields.apply(location: Self.nas, authentication: .basic, trustedPublicKey: Self.pin)
        fields.user.stringValue = ""
        let read = try #require(endpoint(of: fields.readForm(saveName: "NAS")))
        #expect(read.scheme == nil)
        #expect(read.pin == Self.pin)
    }

    /// The whole sheet, from a saved record to what Connect would write back: every field of the
    /// endpoint survives, including the two with no row.
    @Test("a saved WebDAV server round-trips through the whole form")
    func formRoundTrip() throws {
        let location = WebDAVLocation(
            host: "nas", port: 5006, username: "form-round-trip", rootPath: "/home"
        )
        SecretKeychain.store(password: "pw", for: location)
        defer { SecretKeychain.removePassword(for: location) }
        let server = ServerConnection(
            name: "NAS",
            endpoint: .webdav(location: location, authentication: .basic, trustedPublicKey: Self.pin)
        )
        let form = ConnectServerForm(prefill: server).readForm()
        #expect(form?.endpoint == server.endpoint)
        #expect(form?.password == "pw")
        #expect(form?.saveName == "NAS")
    }
}
