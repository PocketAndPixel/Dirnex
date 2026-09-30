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

    @Test("an email username keeps its own @; only host[:port] follows the last @")
    func parseEmailUsername() {
        let location = SMBLocation(url: "smb://oleg.verhoglyad@gmail.com@192.168.1.60/MediaShare")
        #expect(location?.username == "oleg.verhoglyad@gmail.com")
        #expect(location?.host == "192.168.1.60")
        #expect(location?.share == "MediaShare")
        #expect(location?.port == SMBLocation.defaultPort)
        // And it survives the round-trip, so editing the address field can't corrupt the host.
        #expect(location?.url == "smb://oleg.verhoglyad@gmail.com@192.168.1.60/MediaShare")
    }

    @Test("an email username splits correctly even with a port")
    func parseEmailUsernameWithPort() {
        let location = SMBLocation(url: "smb://me@work.com@10.0.0.5:4450/backup")
        #expect(location?.username == "me@work.com")
        #expect(location?.host == "10.0.0.5")
        #expect(location?.port == 4450)
        #expect(location?.share == "backup")
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

    // MARK: - The mount URL's encoding

    /// A share name reaches `URL(string:)`, and on the deployment target that parser is strict.
    ///
    /// Measured 2026-09-09 through `CFURLCreateWithString` (the parser macOS 14's `URL(string:)`
    /// uses): `smb://nas.local/My Share` and `smb://nas.local/Панорама` both return **nil**, while
    /// the percent-encoded spellings parse. A nil there is a mount that fails before it is
    /// attempted — and a share name containing a **space** is far commoner than a non-ASCII one.
    @Test("a share name is percent-encoded for the mount URL")
    func mountShareIsEncoded() {
        #expect(SMBLocation.percentEncodedShare("My Share") == "My%20Share")
        #expect(SMBLocation.percentEncodedShare("Панорама")
            == "%D0%9F%D0%B0%D0%BD%D0%BE%D1%80%D0%B0%D0%BC%D0%B0")
        // The ones that would end or restructure the URL rather than sit in it.
        #expect(SMBLocation.percentEncodedShare("a#b") == "a%23b")
        #expect(SMBLocation.percentEncodedShare("a?b") == "a%3Fb")
        #expect(SMBLocation.percentEncodedShare("a/b") == "a%2Fb")
        #expect(SMBLocation.percentEncodedShare("100%") == "100%25")
    }

    /// The narrowness control: encoding more than necessary would change spellings NetFS already
    /// accepts, and the two that matter are a Windows admin share and an ordinary ampersand name.
    @Test("but an ordinary share name is left exactly as it was")
    func ordinaryShareNamesAreUntouched() {
        for share in ["media", "C$", "R&D", "home", "Time_Machine", "a.b-c~d"] {
            #expect(SMBLocation.percentEncodedShare(share) == share)
        }
    }

    /// The address field and the sidebar keep the *unencoded* string, which is the other half of the
    /// split: it is what the user typed and it has to round-trip through ``SMBLocation/init(url:)``.
    @Test("the displayed url is not encoded, so it still round-trips")
    func displayedURLIsUnencoded() {
        let location = SMBLocation(host: "nas.local", share: "My Share")
        #expect(location.url == "smb://nas.local/My Share")
        #expect(SMBLocation(url: location.url)?.share == "My Share")
    }
}
