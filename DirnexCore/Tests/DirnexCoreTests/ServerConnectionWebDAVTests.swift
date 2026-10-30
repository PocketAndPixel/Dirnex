import Foundation
import Testing

@testable import DirnexCore

/// The WebDAV half of the saved-server model (PLAN.md §M32 Slice 3): the endpoint a connect saves
/// and a restored tab reconnects with, and what it carries beside its location.
@Suite("ServerConnection with WebDAV")
struct ServerConnectionWebDAVTests {
    private static let nas = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")

    private func webdav(
        _ name: String,
        location: WebDAVLocation = nas,
        authentication: WebDAVAuthScheme? = .basic,
        pin: String? = nil
    ) -> ServerConnection {
        ServerConnection(
            name: name,
            endpoint: .webdav(
                location: location,
                authentication: authentication,
                trustedPublicKey: pin
            )
        )
    }

    @Test("a saved account is the WebDAV kind and joins the backend its tabs carry")
    func kindAndBackend() {
        let server = webdav("NAS")
        #expect(server.kind == .webdav)
        #expect(server.endpoint.backendID == Self.nas.backendID)
        #expect(server.endpoint.backendID?.isWebDAV == true)
    }

    /// The tooltip reads as the URL a person would type, not as GNOME's `davs://` descriptor, and an
    /// account with no user is not drawn with a stray `@`.
    @Test("the address is the root's URL, the port stated only when it is not the default")
    func address() {
        #expect(webdav("NAS").address == "https://dirnex-test@nas:5006/")
        let plain = WebDAVLocation(host: "nas", port: 80, username: "", usesTLS: false)
        #expect(webdav("Public", location: plain, authentication: nil).address == "http://nas/")
        let cloud = WebDAVLocation(
            host: "cloud.example.com",
            username: "me@example.com",
            rootPath: "/remote.php/dav/files/me@example.com"
        )
        #expect(webdav("Cloud", location: cloud).address
            == "https://me@example.com@cloud.example.com/remote.php/dav/files/me@example.com")
    }

    @Test("the endpoint round-trips through JSON with its scheme and its pin")
    func codableRoundTrip() throws {
        let original = webdav("NAS", authentication: .digest, pin: "abc=")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ServerConnection.self, from: data) == original)
    }

    /// A record written before a connect settled anything has neither key, and a restored tab of a
    /// public share has no scheme: both must decode, as FTP's time zone does.
    @Test("a stored endpoint with no scheme and no pin decodes with both nil")
    func missingOptionalsDecode() throws {
        let json = """
        {"webdav":{"location":{"host":"nas","port":5006,"username":"u","usesTLS":true,"rootPath":""}}}
        """
        let endpoint = try JSONDecoder().decode(ServerEndpoint.self, from: Data(json.utf8))
        guard case let .webdav(location, authentication, pin) = endpoint else {
            Issue.record("decoded as \(endpoint)")
            return
        }
        #expect(location == WebDAVLocation(host: "nas", port: 5006, username: "u"))
        #expect(authentication == nil)
        #expect(pin == nil)
    }

    /// The other direction of the same tolerance: a session written by a build that knows WebDAV,
    /// read by one that does not, must lose that tab and keep the others (`StoredServerEndpoint`).
    @Test("an endpoint of an unknown kind is read as nothing rather than failing the array")
    func unknownKindIsTolerated() throws {
        let json = #"[{"webdavNext":{"x":1}},{"smb":{"_0":{"host":"nas","port":445}}}]"#
        let stored = try JSONDecoder().decode([StoredServerEndpoint].self, from: Data(json.utf8))
        #expect(stored.count == 2)
        #expect(stored[0].endpoint == nil)
    }

    @Test("settling a record writes the scheme and the pin a connect learned, and nothing else")
    func settle() {
        var store = ServerConnections(connections: [webdav("NAS", authentication: nil)])
        let first = store.settleWebDAV(name: "NAS", authentication: .basic, trustedPublicKey: "pin=")
        #expect(first)
        #expect(store.connection(named: "NAS")?.endpoint == .webdav(
            location: Self.nas, authentication: .basic, trustedPublicKey: "pin="
        ))
        // Unchanged: nothing to write, so the caller persists nothing.
        let again = store.settleWebDAV(name: "NAS", authentication: .basic, trustedPublicKey: "pin=")
        #expect(!again)
    }

    @Test("settling never creates a record, and never touches another kind")
    func settleIsNarrow() {
        let ftp = ServerConnection(
            name: "FTP",
            endpoint: .ftp(
                location: FTPLocation(host: "nas", username: "u"),
                authentication: .password
            )
        )
        var store = ServerConnections(connections: [ftp])
        let otherKind = store.settleWebDAV(
            name: "FTP",
            authentication: .basic,
            trustedPublicKey: "x"
        )
        let missing = store.settleWebDAV(
            name: "Missing",
            authentication: .basic,
            trustedPublicKey: "x"
        )
        #expect(!otherKind)
        #expect(!missing)
        #expect(store.connections == [ftp])
    }

    @Test("an account's password is filed without its root, and a public share files none")
    func keychainAddressing() {
        let home = WebDAVLocation(
            host: "nas",
            port: 5006,
            username: "dirnex-test",
            rootPath: "/home"
        )
        #expect(WebDAVLocation.keychainService == "app.dirnex.webdav")
        #expect(home.keychainAccount == Self.nas.keychainAccount)
        #expect(!home.hasNoStoredSecret)
        #expect(WebDAVLocation(host: "nas", username: "").hasNoStoredSecret)
    }

    /// Read-only through Slice 3; since Slice 4's write half, somewhere a copy can land.
    @Test("a WebDAV backend is a remote connection that accepts uploads")
    func predicates() {
        let id = Self.nas.backendID
        #expect(id.isRemoteConnection)
        #expect(id.acceptsUploads)
        #expect(id.receivesFiles)
        #expect(!id.hasComparableModificationTimes)
    }

    @Test("a restored WebDAV tab needs its connection, and only its own")
    func restoreRequirement() {
        let endpoint = webdav("NAS").endpoint
        let path = VFSPath(backend: Self.nas.backendID, path: "/home")
        #expect(TabRestorePolicy.requirement(for: path, endpoint: endpoint) == .connection(endpoint))
        let other = WebDAVLocation(
            host: "nas",
            port: 5006,
            username: "dirnex-test",
            rootPath: "/home"
        )
        let elsewhere = VFSPath(backend: other.backendID, path: "/")
        #expect(TabRestorePolicy.requirement(for: elsewhere, endpoint: endpoint) == nil)
    }
}
