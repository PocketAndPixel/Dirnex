import Foundation
import Testing

@testable import DirnexCore

/// `WebDAVLocation`: the descriptor a backend id carries, and the mapping between the pane's paths
/// and the server's (PLAN.md §M32 Slice 1).
@Suite("WebDAVLocation")
struct WebDAVLocationTests {
    /// The NAS as Oleg set it up for the milestone: HTTPS on 5006, the account at the server root.
    static let nas = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")

    /// A Nextcloud-shaped account: an e-mail login and a root that contains the same `@`.
    static let nextcloud = WebDAVLocation(
        host: "cloud.example.com",
        username: "me@example.com",
        rootPath: "/remote.php/dav/files/me@example.com/"
    )

    // MARK: - Descriptor

    @Test("a descriptor round-trips every field, for HTTPS and HTTP")
    func descriptorRoundTrips() throws {
        let plain = WebDAVLocation(host: "nas", port: 5005, username: "dirnex-test", usesTLS: false)
        for location in [Self.nas, plain, Self.nextcloud] {
            #expect(WebDAVLocation(descriptor: location.descriptor) == location)
            #expect(location.backendID.webDAVLocation == location)
        }
        #expect(Self.nas.descriptor == "davs://dirnex-test@nas:5006")
        #expect(plain.descriptor == "dav://dirnex-test@nas:5005")
    }

    @Test("an e-mail login survives when the root holds an @ too")
    func emailLoginAndRootWithAt() throws {
        // The authority is cut off at the first `/` before the user is split at its last `@`, so
        // neither `@` can be mistaken for the other. FTP's first-`@` rule would read the user as
        // `me` and the host as `example.com@cloud.example.com`.
        let decoded = try #require(WebDAVLocation(descriptor: Self.nextcloud.descriptor))
        #expect(decoded.username == "me@example.com")
        #expect(decoded.host == "cloud.example.com")
        #expect(decoded.port == 443)
        #expect(decoded.rootPath == "/remote.php/dav/files/me@example.com")
    }

    @Test("a bracketed IPv6 host keeps its own colons")
    func ipv6Host() throws {
        let location = WebDAVLocation(host: "[::1]", port: 8088, username: "u", usesTLS: false)
        let decoded = try #require(WebDAVLocation(descriptor: location.descriptor))
        #expect(decoded.host == "[::1]")
        #expect(decoded.port == 8088)
    }

    @Test("an empty user name is a location without credentials, and round-trips")
    func emptyUserName() throws {
        let location = WebDAVLocation(host: "public.example.com", username: "")
        #expect(!location.hasCredentials)
        #expect(WebDAVLocation(descriptor: location.descriptor) == location)
        #expect(Self.nas.hasCredentials)
    }

    @Test("malformed descriptors are refused", arguments: [
        "dav:/u@h:80", // not the scheme
        "davs://u@h", // no port
        "davs://u@h:", // empty port
        "davs://u@h:0", // port out of range
        "davs://u@h:70000",
        "davs://u@:443", // no host
        "davs://h:443", // no @ at all
        "ftps://u@h:990", // another backend's scheme
        "s3://key@host:443/region/bucket"
    ])
    func malformedDescriptors(_ descriptor: String) {
        #expect(WebDAVLocation(descriptor: descriptor) == nil)
    }

    @Test("isWebDAV recognizes both schemes and nothing else")
    func isWebDAV() {
        #expect(Self.nas.backendID.isWebDAV)
        #expect(VFSBackendID("dav://u@h:80").isWebDAV)
        #expect(!VFSBackendID.local.isWebDAV)
        #expect(!FTPLocation(host: "nas", username: "u").backendID.isWebDAV)
        #expect(!VFSBackendID("sftp://u@h:22").isWebDAV)
    }

    // MARK: - The root

    @Test("every spelling of a root is stored one way", arguments: [
        ("", ""), ("/", ""), ("//", ""),
        ("dav", "/dav"), ("/dav", "/dav"), ("/dav/", "/dav"), ("//dav//files/", "/dav/files")
    ])
    func rootNormalization(_ raw: String, _ stored: String) {
        #expect(WebDAVLocation(host: "h", username: "u", rootPath: raw).rootPath == stored)
    }

    @Test("a backend path maps onto the server under the root, and back")
    func pathMapping() {
        #expect(Self.nas.serverPath(forBackendPath: "/") == "/")
        #expect(Self.nas.serverPath(forBackendPath: "/home/a.txt") == "/home/a.txt")
        #expect(Self.nas.backendPath(forServerPath: "/home/a.txt") == "/home/a.txt")

        let root = "/remote.php/dav/files/me@example.com"
        #expect(Self.nextcloud.serverPath(forBackendPath: "/") == root)
        #expect(Self.nextcloud.serverPath(forBackendPath: "/Docs/a.txt") == root + "/Docs/a.txt")
        #expect(Self.nextcloud.backendPath(forServerPath: root + "/") == "/")
        #expect(Self.nextcloud.backendPath(forServerPath: root + "/Docs/a.txt") == "/Docs/a.txt")
    }

    @Test("a server path outside the root has no backend path")
    func outsideRoot() {
        #expect(
            Self.nextcloud.backendPath(forServerPath: "/remote.php/dav/files/someone-else") == nil
        )
        // A sibling whose name merely starts with the root's last segment is outside it.
        #expect(Self.nextcloud.backendPath(forServerPath: "/remote.php/dav/files/me@example.comX/a")
            == nil)
    }

    @Test("the root is compared as bytes, so a decomposed twin of it is outside")
    func rootComparedAsBytes() {
        let precomposed = "/caf\u{E9}"
        let decomposed = "/cafe\u{301}"
        // The negative control: Swift's own comparison calls these the same string.
        #expect(precomposed == decomposed)
        #expect((decomposed + "/x").hasPrefix(precomposed + "/"))

        let location = WebDAVLocation(host: "h", username: "u", rootPath: precomposed)
        #expect(location.backendPath(forServerPath: precomposed + "/x") == "/x")
        #expect(location.backendPath(forServerPath: decomposed + "/x") == nil)
    }

    // MARK: - URLs

    @Test("the origin spells the port only when it is not the default")
    func origin() {
        #expect(Self.nas.origin() == "https://nas:5006")
        #expect(Self.nas.origin(host: "nas.local") == "https://nas.local:5006")
        #expect(WebDAVLocation(host: "h", username: "u").origin() == "https://h")
        #expect(WebDAVLocation(host: "h", username: "u", usesTLS: false).origin() == "http://h")
        #expect(WebDAVLocation(host: "h", port: 443, username: "u", usesTLS: false).origin()
            == "http://h:443")
    }

    @Test("a URL encodes the name to the strict set, and only a collection ends in a slash")
    func url() {
        #expect(Self.nas.url(forBackendPath: "/home/a b.txt", isCollection: false)
            == "https://nas:5006/home/a%20b.txt")
        #expect(Self.nas.url(forBackendPath: "/home", isCollection: true)
            == "https://nas:5006/home/")
        #expect(Self.nas.url(forBackendPath: "/", isCollection: true) == "https://nas:5006/")
        #expect(Self.nextcloud.url(forBackendPath: "/Docs", isCollection: true, host: "10.0.0.2")
            == "https://10.0.0.2/remote.php/dav/files/me%40example.com/Docs/")
    }

    // MARK: - Keychain

    @Test("the Keychain account leaves the root out and keeps the scheme in")
    func keychainAccount() {
        #expect(Self.nas.keychainAccount == "https:dirnex-test@nas:5006")
        let otherRoot = WebDAVLocation(
            host: "nas",
            port: 5006,
            username: "dirnex-test",
            rootPath: "/home"
        )
        #expect(otherRoot.keychainAccount == Self.nas.keychainAccount)
        #expect(otherRoot.backendID != Self.nas.backendID)
        let plain = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test", usesTLS: false)
        #expect(plain.keychainAccount != Self.nas.keychainAccount)
        #expect(WebDAVLocation.keychainService == "com.dirnex.webdav")
    }
}
