import Foundation
import Testing

@testable import DirnexCore

@Suite("SMBLocation")
struct SMBLocationTests {
    // MARK: - URL formatting

    @Test("a full location renders user, host, and share")
    func urlFormatFull() {
        let location = SMBLocation(host: "nas.local", share: "media", username: "oleg")
        #expect(location.url == "smb://oleg@nas.local/media")
    }

    @Test("a guest mount omits the user, a share-less location stops at the host")
    func urlFormatGuestAndShareless() {
        #expect(SMBLocation(host: "nas.local", share: "media").url == "smb://nas.local/media")
        #expect(SMBLocation(host: "nas.local").url == "smb://nas.local")
        #expect(SMBLocation(host: "nas.local", username: "oleg").url == "smb://oleg@nas.local")
    }

    @Test("the default port is elided, a non-default port is rendered")
    func urlFormatPort() {
        #expect(SMBLocation(host: "h", share: "s").port == SMBLocation.defaultPort)
        #expect(SMBLocation(host: "h", share: "s").url == "smb://h/s")
        #expect(SMBLocation(host: "h", share: "s", port: 4450).url == "smb://h:4450/s")
    }

    @Test("empty share and username normalize to nil (guest / share-less)")
    func emptyStringsNormalizeToNil() {
        let location = SMBLocation(host: "h", share: "", username: "")
        #expect(location.share == nil)
        #expect(location.username == nil)
        #expect(location.url == "smb://h")
    }

    // MARK: - URL parsing

    @Test("parse a full smb://user@host/share URL")
    func parseFull() {
        let location = SMBLocation(url: "smb://oleg@nas.local/media")
        #expect(location?.host == "nas.local")
        #expect(location?.share == "media")
        #expect(location?.username == "oleg")
        #expect(location?.port == SMBLocation.defaultPort)
    }

    @Test("parse a guest URL (no user) and a share-less URL")
    func parseGuestAndShareless() {
        let guest = SMBLocation(url: "smb://nas.local/media")
        #expect(guest?.username == nil)
        #expect(guest?.share == "media")

        let shareless = SMBLocation(url: "smb://nas.local")
        #expect(shareless?.host == "nas.local")
        #expect(shareless?.share == nil)
        #expect(shareless?.username == nil)
    }

    @Test("parse a host:port URL, splitting the trailing numeric port")
    func parsePort() {
        let location = SMBLocation(url: "smb://user@10.0.0.5:4450/backup")
        #expect(location?.host == "10.0.0.5")
        #expect(location?.port == 4450)
        #expect(location?.share == "backup")
        #expect(location?.username == "user")
    }

    @Test("only the first path component is the share; deeper subpaths are dropped")
    func parseTakesFirstShareComponent() {
        let location = SMBLocation(url: "smb://host/share/sub/dir")
        #expect(location?.share == "share")
    }

    @Test("a trailing slash after the host is a share-less location, not an empty share")
    func parseTrailingSlash() {
        let location = SMBLocation(url: "smb://host/")
        #expect(location?.host == "host")
        #expect(location?.share == nil)
    }

    @Test("malformed URLs decode to nil")
    func parseMalformed() {
        #expect(SMBLocation(url: "sftp://user@host/share") == nil) // wrong scheme
        #expect(SMBLocation(url: "smb://") == nil) // no host
        #expect(SMBLocation(url: "smb:///share") == nil) // empty host before the share
        #expect(SMBLocation(url: "smb://user@/share") == nil) // empty host after the user
    }

    @Test("a non-numeric colon suffix stays part of the host, port defaults")
    func parseNonNumericColonStaysInHost() {
        let location = SMBLocation(url: "smb://a:b/share")
        #expect(location?.host == "a:b")
        #expect(location?.port == SMBLocation.defaultPort)
        #expect(location?.share == "share")
    }

    // MARK: - Round-trips

    @Test("every canonical form round-trips URL → parse → URL")
    func urlRoundTrip() {
        for url in [
            "smb://oleg@nas.local/media",
            "smb://nas.local/media",
            "smb://nas.local",
            "smb://oleg@nas.local",
            "smb://user@10.0.0.5:4450/backup"
        ] {
            #expect(SMBLocation(url: url)?.url == url)
        }
    }

    @Test("a location survives JSON Codable round-tripping")
    func codableRoundTrip() throws {
        let original = SMBLocation(host: "nas.local", share: "media", username: "oleg", port: 4450)
        let decoded = try JSONDecoder().decode(
            SMBLocation.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    // MARK: - Keychain

    @Test("keychain account is the scheme-less URL, service is the SMB service")
    func keychainAccount() {
        let location = SMBLocation(host: "nas.local", share: "media", username: "oleg")
        #expect(location.keychainAccount == "oleg@nas.local/media")
        #expect(SMBLocation.keychainService == "com.dirnex.smb")
        // Two shares on the same host under the same user don't collide.
        let other = SMBLocation(host: "nas.local", share: "backup", username: "oleg")
        #expect(location.keychainAccount != other.keychainAccount)
    }
}
