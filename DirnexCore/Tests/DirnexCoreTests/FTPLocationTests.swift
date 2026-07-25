import Foundation
import Testing

@testable import DirnexCore

@Suite("FTPLocation")
struct FTPLocationTests {
    @Test("each security mode gets its own unambiguous scheme")
    func descriptorCarriesSecurityMode() {
        #expect(FTPLocation(host: "nas.local", username: "sa", security: .plain).descriptor
            == "ftp://sa@nas.local:21")
        #expect(FTPLocation(host: "nas.local", username: "sa", security: .explicit).descriptor
            == "ftpes://sa@nas.local:21")
        #expect(FTPLocation(host: "nas.local", username: "sa", security: .implicit).descriptor
            == "ftps://sa@nas.local:990")
    }

    /// The reason three schemes exist rather than two: a saved server must come back as the mode it
    /// was saved with, and `ftps://` already means *implicit* to `curl` and the RFC.
    @Test("every mode round-trips through its descriptor")
    func descriptorRoundTrips() throws {
        for security in FTPSecurity.allCases {
            let original = FTPLocation(
                host: "nas.local",
                port: 2121,
                username: "sa",
                security: security
            )
            let decoded = try #require(FTPLocation(descriptor: original.descriptor))
            #expect(decoded == original)
            #expect(decoded.security == security)
        }
    }

    @Test("a descriptor round-trips through a backend id")
    func backendIDRoundTrips() throws {
        let location = FTPLocation(host: "nas.local", username: "sa", security: .explicit)
        let recovered = try #require(VFSBackendID.ftp(location).ftpLocation)
        #expect(recovered == location)
        #expect(VFSBackendID.ftp(location).isFTP)
    }

    @Test("ftps:// is not mistaken for ftp:// plus a stray s")
    func longestSchemePrefixWins() throws {
        let implicitLocation = try #require(FTPLocation(descriptor: "ftps://sa@nas.local:990"))
        #expect(implicitLocation.security == .implicit)
        #expect(implicitLocation.username == "sa")

        let plainLocation = try #require(FTPLocation(descriptor: "ftp://sa@nas.local:21"))
        #expect(plainLocation.security == .plain)
    }

    @Test("a non-FTP or malformed descriptor is rejected")
    func rejectsMalformedDescriptors() {
        #expect(FTPLocation(descriptor: "sftp://sa@nas.local:22") == nil)
        #expect(FTPLocation(descriptor: "ftp://nas.local:21") == nil) // no username
        #expect(FTPLocation(descriptor: "ftp://sa@nas.local") == nil) // no port
        #expect(FTPLocation(descriptor: "ftp://sa@:21") == nil) // no host
        #expect(FTPLocation(descriptor: "ftp://@nas.local:21") == nil) // empty username
        #expect(FTPLocation(descriptor: "ftp://sa@nas.local:notaport") == nil)
        #expect(!VFSBackendID("local").isFTP)
        #expect(!VFSBackendID("sftp://sa@h:22").isFTP)
    }

    @Test("an SFTP id is not an FTP id, and vice versa")
    func schemesDoNotCollide() {
        let ftp = FTPLocation(host: "h", username: "u", security: .plain)
        #expect(ftp.backendID.sftpLocation == nil)

        let sftp = SFTPLocation(host: "h", username: "u")
        #expect(sftp.backendID.ftpLocation == nil)
        #expect(!sftp.backendID.isFTP)
    }

    // MARK: - curl URLs

    /// The descriptor's scheme and the URL's scheme deliberately differ: the descriptor round-trips
    /// three modes, the URL says what `curl` understands (explicit TLS is `ftp://` + `--ssl-reqd`).
    @Test("the curl URL uses ftp:// for plain and explicit, ftps:// only for implicit")
    func curlURLSchemes() {
        #expect(FTPLocation(host: "h", username: "u", security: .plain).url(forRemotePath: "/a")
            == "ftp://h:21/a")
        #expect(FTPLocation(host: "h", username: "u", security: .explicit).url(forRemotePath: "/a")
            == "ftp://h:21/a")
        #expect(FTPLocation(host: "h", username: "u", security: .implicit).url(forRemotePath: "/a")
            == "ftps://h:990/a")
    }

    @Test("a relative remote path is anchored at the root")
    func urlAnchorsRelativePaths() {
        let location = FTPLocation(host: "h", port: 21, username: "u", security: .plain)
        #expect(location.url(forRemotePath: "pub/a") == "ftp://h:21/pub/a")
    }

    // MARK: - Keychain

    /// Plain FTP and FTPS to the same account are separate trust decisions and may genuinely hold
    /// different passwords, so they must not share a Keychain entry.
    @Test("the Keychain account distinguishes the security mode")
    func keychainAccountSeparatesSecurityModes() {
        let plain = FTPLocation(host: "nas.local", port: 21, username: "sa", security: .plain)
        let secure = FTPLocation(host: "nas.local", port: 21, username: "sa", security: .explicit)
        #expect(plain.keychainAccount != secure.keychainAccount)
        #expect(plain.keychainAccount == "plain:sa@nas.local:21")
        #expect(secure.keychainAccount == "explicit:sa@nas.local:21")
    }

    @Test("the anonymous account is recognized")
    func recognizesAnonymous() {
        #expect(FTPLocation(host: "h", username: "anonymous", security: .plain).isAnonymous)
        #expect(!FTPLocation(host: "h", username: "sa", security: .plain).isAnonymous)
    }

    @Test("an explicit port overrides the mode's default")
    func explicitPortWins() {
        #expect(FTPLocation(host: "h", port: 2121, username: "u", security: .explicit).port == 2121)
        #expect(FTPLocation(host: "h", username: "u", security: .explicit).port == 21)
    }

    @Test("a location codes and decodes as JSON with its security mode")
    func codableRoundTrip() throws {
        let original = FTPLocation(
            host: "nas.local",
            port: 2121,
            username: "sa",
            security: .implicit
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(FTPLocation.self, from: data) == original)
    }
}

@Suite("ServerConnection with FTP")
struct ServerConnectionFTPTests {
    private let location = FTPLocation(host: "nas.local", username: "sa", security: .explicit)

    @Test("an FTP endpoint reports its kind and address")
    func kindAndAddress() {
        let connection = ServerConnection(
            name: "NAS",
            endpoint: .ftp(location: location, authentication: .password)
        )
        #expect(connection.kind == .ftp)
        #expect(connection.address == "ftpes://sa@nas.local:21")
    }

    @Test("a saved FTP server round-trips as JSON, trusted key included")
    func codableRoundTrip() throws {
        let connection = ServerConnection(
            name: "NAS",
            endpoint: .ftp(
                location: location,
                authentication: .password,
                trustedPublicKey: "NWrJwng2ZjCZklZSMVK1IsolOd+LavrDTCcNa+oHnJ4="
            )
        )
        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(ServerConnection.self, from: data)
        #expect(decoded == connection)

        guard case let .ftp(_, _, trustedPublicKey) = decoded.endpoint else {
            Issue.record("expected an FTP endpoint")
            return
        }
        #expect(trustedPublicKey == "NWrJwng2ZjCZklZSMVK1IsolOd+LavrDTCcNa+oHnJ4=")
    }

    /// The stored JSON must never carry the password — only the coordinates and the *method*.
    @Test("a saved FTP server spills no credential")
    func savedServerHoldsNoSecret() throws {
        let connection = ServerConnection(
            name: "NAS",
            endpoint: .ftp(location: location, authentication: .password)
        )
        let json = try #require(String(data: try JSONEncoder().encode(connection), encoding: .utf8))
        #expect(!json.lowercased().contains("password\":\"")) // no value, only the method marker
        #expect(json.contains("nas.local"))
    }

    @Test("FTP servers coexist with SFTP and SMB in one store")
    func coexistsWithOtherKinds() {
        var store = ServerConnections()
        store.save(
            ServerConnection(
                name: "NAS",
                endpoint: .ftp(location: location, authentication: .password)
            )
        )
        store.save(ServerConnection(
            name: "Shell",
            endpoint: .sftp(
                location: SFTPLocation(host: "h", username: "u"),
                authentication: .password
            )
        ))
        #expect(store.connections.count == 2)
        #expect(store.connection(named: "NAS")?.kind == .ftp)
        #expect(store.connection(named: "Shell")?.kind == .sftp)
    }

    /// Plain FTP and FTPS to the same host are different servers; saving both must not collapse
    /// them. They are distinguished by *name* (the store's identity) and carry different endpoints.
    @Test("the same host saved plain and secure stays two entries")
    func plainAndSecureAreDistinct() {
        var store = ServerConnections()
        let plain = FTPLocation(host: "nas.local", username: "sa", security: .plain)
        store.save(
            ServerConnection(
                name: "NAS (FTP)",
                endpoint: .ftp(location: plain, authentication: .password)
            )
        )
        store.save(
            ServerConnection(
                name: "NAS (FTPS)",
                endpoint: .ftp(location: location, authentication: .password)
            )
        )
        #expect(store.connections.count == 2)
        #expect(store.connection(named: "NAS (FTP)")?.address == "ftp://sa@nas.local:21")
        #expect(store.connection(named: "NAS (FTPS)")?.address == "ftpes://sa@nas.local:21")
    }
}
