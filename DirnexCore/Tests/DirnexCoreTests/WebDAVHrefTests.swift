import Foundation
import Testing

@testable import DirnexCore

/// Reading a server's hrefs and building a request's path (PLAN.md §M32 Slice 1).
///
/// The hrefs below are copied from the NAS's own answers (2026-10-22, `Fixtures/WebDAV`), where a
/// name was uploaded and listed back, so each pairs what was stored with what the server said.
@Suite("WebDAVHref")
struct WebDAVHrefTests {
    @Test("lowercase hex decodes to the bytes that were stored", arguments: [
        (
            "/home/x/%d0%9f%d1%80%d0%b8%d0%b2%d0%b5%d1%82%20%d0%bc%d0%b8%d1%80.txt",
            "/home/x/Привет мир.txt"
        ),
        ("/home/x/%e6%97%a5%e6%9c%ac%e8%aa%9e.txt", "/home/x/日本語.txt"),
        ("/home/x/%20leading%20space.txt", "/home/x/ leading space.txt"),
        ("/home/x/.hidden", "/home/x/.hidden")
    ])
    func decodesStoredNames(_ href: String, _ stored: String) throws {
        let path = try #require(WebDAVHref.serverPath(fromHref: href))
        #expect(path.utf8.elementsEqual(stored.utf8))
    }

    @Test("a + is a plus, and the other literal sub-delimiters stay what they are")
    func literalSubDelimiters() throws {
        // The XML parser has already turned `&amp;` into `&` by the time an href gets here.
        let path = try #require(
            WebDAVHref.serverPath(fromHref: "/home/x/a%23b%25c;d+e%3ff&g=h%5b1%5d.txt")
        )
        #expect(path == "/home/x/a#b%c;d+e?f&g=h[1].txt")
        // The negative control: S3's form decoding, right for S3 and wrong here, renames the file.
        #expect(S3Key.decodingURLEncoding("d+e") == "d e")
    }

    @Test("a decomposed é stays decomposed")
    func decomposedNameKeepsItsBytes() throws {
        let path = try #require(WebDAVHref.serverPath(fromHref: "/home/x/cafe%cc%81.txt"))
        #expect(Array(path.utf8) == Array("/home/x/cafe\u{301}.txt".utf8))
        #expect(Array(path.utf8) != Array("/home/x/caf\u{E9}.txt".utf8))
    }

    @Test("a collection's trailing slash is not part of its path")
    func trailingSlash() {
        #expect(WebDAVHref.serverPath(fromHref: "/home/x/") == "/home/x")
        #expect(WebDAVHref.serverPath(fromHref: "/home") == "/home")
        #expect(WebDAVHref.serverPath(fromHref: "/") == "/")
        #expect(WebDAVHref.serverPath(fromHref: "\n/home/x/\n") == "/home/x")
    }

    @Test("an absolute URL keeps only its path")
    func absoluteURL() {
        #expect(
            WebDAVHref.serverPath(fromHref: "https://nas.local:5006/home/a%20b.txt") == "/home/a b.txt"
        )
        #expect(WebDAVHref.serverPath(fromHref: "http://host") == "/")
        // A segment that merely contains `://` is a name, not a scheme.
        #expect(WebDAVHref.serverPath(fromHref: "/a://b") == "/a:/b")
    }

    @Test("a literal ? or # ends the path; encoded, they are part of the name")
    func queryAndFragment() {
        #expect(WebDAVHref.serverPath(fromHref: "/home/a.txt?version=2") == "/home/a.txt")
        #expect(WebDAVHref.serverPath(fromHref: "/home/a.txt#top") == "/home/a.txt")
        #expect(WebDAVHref.serverPath(fromHref: "/home/a%3f%23.txt") == "/home/a?#.txt")
    }

    @Test("hrefs nothing can be made from are refused", arguments: [
        "/home/a%2Fb", // an encoded slash would turn one name into two segments
        "/home/%2e%2e/etc", // `..` once decoded
        "/home/./a",
        "/home/%ff.txt", // not UTF-8 once decoded
        "/home/100%.txt", // a stray percent
        "relative/a.txt", // no base anyone has seen
        "opaquelocktoken:4afd230e-bebe-403d-b43c-53fc26fb4499", // a lock token, not a resource
        ""
    ])
    func refusals(_ href: String) {
        #expect(WebDAVHref.serverPath(fromHref: href) == nil)
    }

    // MARK: - Comparing paths

    @Test("paths compare as bytes, ignoring a trailing slash")
    func samePath() {
        #expect(WebDAVHref.samePath("/home/x/", "/home/x"))
        #expect(WebDAVHref.samePath("//home//x", "/home/x"))
        #expect(!WebDAVHref.samePath("/home/x", "/home/X"))
        // Two different files on the NAS, and one string to Swift.
        #expect("/caf\u{E9}" == "/cafe\u{301}")
        #expect(!WebDAVHref.samePath("/caf\u{E9}", "/cafe\u{301}"))
    }

    @Test("parent and name")
    func parentAndName() {
        #expect(WebDAVHref.parent(of: "/home/x/a.txt") == "/home/x")
        #expect(WebDAVHref.parent(of: "/home") == "/")
        #expect(WebDAVHref.parent(of: "/") == nil)
        #expect(WebDAVHref.name(of: "/home/x/") == "x")
        #expect(WebDAVHref.name(of: "/") == nil)
    }

    // MARK: - Encoding

    @Test("only the unreserved set and the separator go out literally")
    func encodedPath() {
        #expect(WebDAVHref.encodedPath("/A-z_0.9~/b") == "/A-z_0.9~/b")
        #expect(
            WebDAVHref.encodedPath("/a b;c?d#e+f&g=h[1]%") == "/a%20b%3Bc%3Fd%23e%2Bf%26g%3Dh%5B1%5D%25"
        )
        #expect(WebDAVHref.encodedPath("/Папка") == "/%D0%9F%D0%B0%D0%BF%D0%BA%D0%B0")
        #expect(WebDAVHref.encodedPath("/cafe\u{301}") == "/cafe%CC%81")
        #expect(WebDAVHref.encodedPath("/caf\u{E9}") == "/caf%C3%A9")
    }

    @Test("what is sent comes back as the same bytes, in the server's hex case")
    func roundTripThroughTheServersSpelling() throws {
        // The NAS echoed the Cyrillic folder this way in its 424 body.
        let sent = WebDAVHref.encodedPath("/home/dirnex-webdav-fixture/Папка/inside.txt")
        let echoed = "/home/dirnex-webdav-fixture/%d0%9f%d0%b0%d0%bf%d0%ba%d0%b0/inside.txt"
        // Compared raw, the server's answer is not the request: the hex case differs.
        #expect(sent != echoed)
        let decoded = try #require(WebDAVHref.serverPath(fromHref: echoed))
        #expect(WebDAVHref.samePath(decoded, "/home/dirnex-webdav-fixture/Папка/inside.txt"))
    }

    @Test("every odd name survives encode then decode", arguments: [
        "Привет мир.txt", "cafe\u{301}.txt", "caf\u{E9}.txt", "a#b%c;d+e?f&g=h[1].txt",
        " leading space.txt", "trailing ", ".hidden", "日本語.txt", "100%", "a\u{1F600}b"
    ])
    func encodeDecodeRoundTrip(_ name: String) throws {
        let path = "/dir/" + name
        let decoded = try #require(WebDAVHref.serverPath(fromHref: WebDAVHref.encodedPath(path)))
        #expect(Array(decoded.utf8) == Array(path.utf8))
    }
}
