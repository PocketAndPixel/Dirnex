import Foundation
import Testing

@testable import DirnexCore

/// `WebDAVAddress`: what the connect sheet's Host field makes of a pasted URL, a `host:port`, or a
/// bare host (PLAN.md §M32 Slice 3).
@Suite("WebDAVAddress")
struct WebDAVAddressTests {
    @Test("a bare host says nothing else, so every other field is left alone")
    func bareHost() throws {
        let address = try #require(WebDAVAddress.parse("  nas  "))
        #expect(address == WebDAVAddress(host: "nas"))
        #expect(!address.carriesMoreThanHost)
    }

    @Test("host:port sets the port and keeps the scheme the user chose")
    func hostAndPort() throws {
        let address = try #require(WebDAVAddress.parse("nas:5006"))
        #expect(address == WebDAVAddress(host: "nas", port: 5006))
        #expect(address.usesTLS == nil)
        #expect(address.carriesMoreThanHost)
    }

    @Test("Nextcloud's WebDAV URL fills the scheme, the root and nothing it did not say")
    func nextcloudURL() throws {
        let address = try #require(WebDAVAddress.parse(
            "https://cloud.example.com/remote.php/dav/files/me%40example.com/"
        ))
        #expect(address.host == "cloud.example.com")
        #expect(address.usesTLS == true)
        #expect(address.port == nil)
        // Decoded, as `WebDAVLocation.rootPath` stores it; it is encoded again per request.
        #expect(address.rootPath == "/remote.php/dav/files/me@example.com")
        #expect(address.username == nil)
    }

    @Test("the NAS's URL over plain HTTP, with a user and a password, keeps only the user")
    func userInfo() throws {
        let address = try #require(WebDAVAddress.parse("http://dirnex-test:secret@nas:5005"))
        #expect(address == WebDAVAddress(
            host: "nas", port: 5005, usesTLS: false, rootPath: nil, username: "dirnex-test"
        ))
    }

    @Test("an e-mail login in a URL keeps its own @, and is decoded")
    func emailLogin() throws {
        let raw = try #require(WebDAVAddress.parse("https://me@example.com@cloud.example.com/dav"))
        #expect(raw.username == "me@example.com")
        #expect(raw.host == "cloud.example.com")
        let encoded = try #require(WebDAVAddress.parse("https://me%40example.com@cloud.example.com"))
        #expect(encoded.username == "me@example.com")
    }

    @Test("dav, davs, webdav and webdavs are read as the schemes they stand for, in any case")
    func schemes() {
        #expect(WebDAVAddress.parse("davs://nas")?.usesTLS == true)
        #expect(WebDAVAddress.parse("WebDAVs://nas")?.usesTLS == true)
        #expect(WebDAVAddress.parse("dav://nas")?.usesTLS == false)
        #expect(WebDAVAddress.parse("HTTP://nas")?.usesTLS == false)
    }

    @Test("an explicit / is the server root, and a query or fragment ends a URL's path")
    func rootQueryAndFragment() {
        #expect(WebDAVAddress.parse("https://nas:5006/")?.rootPath?.isEmpty == true)
        #expect(WebDAVAddress.parse("https://nas/dav/?x=1")?.rootPath == "/dav")
        #expect(WebDAVAddress.parse("https://nas#top")?.rootPath?.isEmpty == true)
        #expect(WebDAVAddress.parse("https://nas#top")?.host == "nas")
    }

    /// Negative control for the URL rule: the same `%` without a scheme is a character of a folder
    /// name, as it is in the Path field.
    @Test("without a scheme a path is literal, so % is a character")
    func literalPathWithoutScheme() throws {
        let address = try #require(WebDAVAddress.parse("nas/100%25 done"))
        #expect(address.rootPath == "/100%25 done")
        #expect(WebDAVAddress.parse("https://nas/100%25 done")?.rootPath == "/100% done")
    }

    @Test("a bracketed IPv6 literal keeps its brackets and its own colons")
    func ipv6() {
        #expect(WebDAVAddress.parse("http://[::1]:8088/basic") == WebDAVAddress(
            host: "[::1]", port: 8088, usesTLS: false, rootPath: "/basic"
        ))
        #expect(WebDAVAddress.parse("[fe80::1]") == WebDAVAddress(host: "[fe80::1]"))
        // Unbracketed, a port cannot be told from the address, so none is taken.
        #expect(WebDAVAddress.parse("fe80::1") == WebDAVAddress(host: "fe80::1"))
    }

    @Test("what cannot be an address is refused rather than half-read")
    func refusals() {
        #expect(WebDAVAddress.parse("") == nil)
        #expect(WebDAVAddress.parse("   ") == nil)
        #expect(WebDAVAddress.parse("ftp://nas") == nil)
        #expect(WebDAVAddress.parse("nas:0") == nil)
        #expect(WebDAVAddress.parse("nas:70000") == nil)
        #expect(WebDAVAddress.parse("nas:abc") == nil)
        #expect(WebDAVAddress.parse("https://:5006") == nil)
        #expect(WebDAVAddress.parse("https://user@/x") == nil)
        // The href rules: a `..` segment or an encoded `/` would name a different folder.
        #expect(WebDAVAddress.parse("https://nas/a/../b") == nil)
        #expect(WebDAVAddress.parse("https://nas/a%2Fb") == nil)
    }
}
