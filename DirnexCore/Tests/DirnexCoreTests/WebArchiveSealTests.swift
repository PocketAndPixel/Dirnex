import Foundation
import Testing

@testable import DirnexCore

@Suite("WebArchiveSeal")
struct WebArchiveSealTests {
    private static let sealed = WebArchiveSeal.scheme + "://"

    // MARK: - The captures

    @Test("every URL in WebKit's own archive moves into the sealed scheme, paths kept")
    func sealsWebKitArchive() throws {
        let archive = try WebArchiveFixtures.archive("webkit-types.webarchive")
        let result = WebArchiveSeal.seal(archive)
        #expect(result.archive.allURLs.allSatisfy { $0.hasPrefix(Self.sealed) })
        #expect(result.archive.mainResource.url == Self.sealed + "o1/types.html")
        #expect(result.origins == [Self.sealed + "o1": WebArchiveFixtures.origin])
        #expect(result.archive.subframes.map(\.frameName) == archive.subframes.map(\.frameName))
        // WebKit keeps the page's own relative references, which the seal has no reason to touch.
        #expect(result.archive.mainResource.data == archive.mainResource.data)
    }

    @Test("Chrome's frames, converted and sealed, name no real origin and no cid: anywhere")
    func sealsChromeFrames() throws {
        let converted = try MHTMLArchive.webArchive(
            from: WebArchiveFixtures.data("chrome-frames.mhtml")
        )
        let result = WebArchiveSeal.seal(converted)
        let archive = result.archive
        #expect(archive.allURLs.allSatisfy { $0.hasPrefix(Self.sealed) })
        for resource in archive.allResources where WebArchiveSeal.isText(resource) {
            let text = WebArchiveFixtures.text(resource.data).lowercased()
            #expect(!text.contains("127.0.0.1:8765"), "\(resource.url)")
            #expect(!text.contains("cid:"), "\(resource.url)")
        }
        let page = WebArchiveFixtures.text(archive.mainResource.data)
        #expect(
            page.contains(
                #"src="x-dirnex-archive://cid/frame-5F5CF8022664EC61DBF8FF30DE047FC7@mhtml.blink""#
            )
        )
        #expect(page.contains(#"src="x-dirnex-archive://o1/dir%20with%20space/r%20%C3%A9%20d.png""#))
        let frame = try #require(archive.subframes.first)
        #expect(
            frame.mainResource.url == Self.sealed + "cid/frame-5F5CF8022664EC61DBF8FF30DE047FC7@mhtml.blink"
        )
        #expect(WebArchiveFixtures.text(frame.mainResource.data)
            .contains(
                #"href="x-dirnex-archive://cid/css-0fdf9d14-d4b8-4d75-bcae-7502d4c86e83@mhtml.blink""#
            ))
        // The windows-1252 byte is still there: the rewrite touches only ASCII runs.
        #expect(archive.mainResource.data.range(of: Data([0x63, 0x61, 0x66, 0xE9])) != nil)
        // An image is bytes, and is left as it came.
        let image = try #require(archive.subresources.first { $0.mimeType == "image/png" })
        #expect(image.data == (try WebArchiveFixtures.png()))
    }

    @Test("a sealed archive survives the property list round trip WebKit is handed")
    func sealedRoundTrip() throws {
        let converted = try MHTMLArchive.webArchive(
            from: WebArchiveFixtures.data("chrome-frames.mhtml")
        )
        let archive = WebArchiveSeal.seal(converted).archive
        #expect(WebArchive(propertyList: try archive.propertyListData()) == archive)
    }

    // MARK: - Where a token stands alone

    @Test("an origin is rewritten only as a whole origin")
    func originBoundaries() {
        let rewritten = Self.rewrite(
            origins: ["http://a.com/page"],
            text: """
            1 http://a.com/x 2 HTTP://A.COM/y 3 "http://a.com" 4 http://a.com.evil/z 5 http://a.com:8080/w \
            6 xhttp://a.com/v 7 https://a.com/u 8 url(http://a.com/t)
            """
        )
        #expect(rewritten == """
        1 x-dirnex-archive://o1/x 2 x-dirnex-archive://o1/y 3 "x-dirnex-archive://o1" 4 http://a.com.evil/z \
        5 http://a.com:8080/w 6 xhttp://a.com/v 7 https://a.com/u 8 url(x-dirnex-archive://o1/t)
        """)
    }

    @Test("an origin with a port is its own origin")
    func portedOrigin() {
        let rewritten = Self.rewrite(
            origins: ["http://a.com/page", "http://a.com:8080/img.png"],
            text: "http://a.com/x http://a.com:8080/y"
        )
        #expect(rewritten == "x-dirnex-archive://o1/x x-dirnex-archive://o2/y")
    }

    @Test("a protocol-relative reference is rewritten where a reference can start, and nowhere else")
    func protocolRelative() {
        let rewritten = Self.rewrite(
            origins: ["https://a.com/page"],
            text: #"src="//a.com/x" url(//a.com/y) srcset="a.png 1x, //a.com/b.png 2x" /path//a.com/z"#
        )
        #expect(
            rewritten == #"src="//o1/x" url(//o1/y) srcset="a.png 1x, //o1/b.png 2x" /path//a.com/z"#
        )
    }

    @Test("a host saved under two schemes is reached protocol-relatively through the page's own")
    func protocolRelativePrefersPageScheme() {
        let rewritten = Self.rewrite(
            origins: ["http://cdn.com/x.png", "https://page.com/", "https://cdn.com/y.png"],
            text: #"src="//cdn.com/z""#,
            page: "https://page.com/"
        )
        // o1 is the page; cdn.com is o2 over http and o3 over https, and the page is https.
        #expect(rewritten == #"src="//o3/z""#)
    }

    @Test("the rewrite never rescans its own output, whatever the archive calls its hosts")
    func singlePass() {
        let rewritten = Self.rewrite(
            origins: ["http://real/page", "http://o1/a.png"],
            text: #"<img src="http://o1/a.png"> <a href="//real/x">"#
        )
        #expect(rewritten == #"<img src="x-dirnex-archive://o2/a.png"> <a href="//o1/x">"#)
    }

    @Test("a cid: reference moves under the cid host, in any case, and only whole")
    func contentIDs() {
        let archive = WebArchive(
            mainResource: .init(url: "http://a.com/", mimeType: "text/html", data: Data(
                #"<img src="cid:Part1@x"> <img src="CID:part1@x"> <img src="cid:part1@xy">"#.utf8
            )),
            subresources: [.init(url: "cid:Part1@x", mimeType: "image/png", data: Data([1]))]
        )
        let result = WebArchiveSeal.seal(archive).archive
        #expect(result.subresources.map(\.url) == [Self.sealed + "cid/Part1@x"])
        #expect(WebArchiveFixtures.text(result.mainResource.data) == """
        <img src="x-dirnex-archive://cid/Part1@x"> <img src="x-dirnex-archive://cid/Part1@x"> <img src="cid:part1@xy">
        """)
    }

    @Test("a cid: holding a slash or a space stays one path segment")
    func contentIDEncoded() {
        #expect(WebArchiveSeal.sealedCID("a/b c#d") == Self.sealed + "cid/a%2Fb%20c%23d")
        #expect(WebArchiveSeal.sealedCID("é") == Self.sealed + "cid/%C3%A9")
    }

    // MARK: - What is left alone

    @Test("binary resources and wide encodings are not rewritten")
    func leavesBytesAlone() {
        let text = Data("http://a.com/x".utf8)
        let utf16 = Data([0xFF, 0xFE]) + "http://a.com/x".data(using: .utf16LittleEndian)!
        let archive = WebArchive(
            mainResource: .init(url: "http://a.com/", mimeType: "text/html", data: text),
            subresources: [
                .init(url: "http://a.com/i.png", mimeType: "image/png", data: text),
                .init(
                    url: "http://a.com/w.css",
                    mimeType: "text/css",
                    textEncodingName: "utf-16",
                    data: text
                ),
                .init(url: "http://a.com/b.js", mimeType: "application/javascript", data: utf16)
            ]
        )
        let result = WebArchiveSeal.seal(archive).archive
        #expect(result.mainResource.data == Data("x-dirnex-archive://o1/x".utf8))
        #expect(result.subresources.map(\.data) == [text, text, utf16])
    }

    @Test("data: and about: URLs cannot reach the network and are kept")
    func opaqueURLsKept() {
        let archive = WebArchive(
            mainResource: .init(url: "about:blank", mimeType: "text/html", data: Data()),
            subresources: [
                .init(url: "data:image/png;base64,AA==", mimeType: "image/png", data: Data())
            ]
        )
        let result = WebArchiveSeal.seal(archive)
        #expect(result.archive == archive)
        #expect(result.origins.isEmpty)
    }

    @Test("the scheme is told apart from a relative path, and an origin from what follows it")
    func urlAnatomy() {
        #expect(WebArchiveSeal.scheme(of: "HTTP://a") == "HTTP")
        #expect(WebArchiveSeal.scheme(of: "cid:x") == "cid")
        #expect(WebArchiveSeal.scheme(of: "img/a:b.png") == nil)
        #expect(WebArchiveSeal.scheme(of: "1x:y") == nil)
        #expect(
            WebArchiveSeal.splitOrigin("https://a.com:8/p?q#f")! == ("https://a.com:8", "/p?q#f")
        )
        #expect(WebArchiveSeal.splitOrigin("http://a.com")! == ("http://a.com", ""))
        #expect(WebArchiveSeal.splitOrigin("file:///C:/x.htm")! == ("file://", "/C:/x.htm"))
        #expect(WebArchiveSeal.splitOrigin("cid:x") == nil)
    }

    // MARK: - Undoing it for one URL

    @Test("a sealed URL maps back to where its author pointed it")
    func originalURL() throws {
        let converted = try MHTMLArchive.webArchive(
            from: WebArchiveFixtures.data("chrome-frames.mhtml")
        )
        let result = WebArchiveSeal.seal(converted)
        #expect(
            result.originalURL(for: Self.sealed + "o1/a/b?c#d") == WebArchiveFixtures.origin + "/a/b?c#d"
        )
        #expect(result.originalURL(for: "X-DIRNEX-ARCHIVE://O1") == WebArchiveFixtures.origin)
        #expect(result.originalURL(for: Self.sealed + "cid/a%2Fb") == "cid:a/b")
        #expect(result.originalURL(for: Self.sealed + "o9/x") == nil)
        #expect(result.originalURL(for: "https://elsewhere.example/") == nil)
    }

    // MARK: - Helpers

    /// `text` as the page of an archive whose resources come from `origins`, sealed.
    private static func rewrite(origins: [String], text: String, page: String? = nil) -> String {
        let urls = page.map { [$0] + origins.filter { $0 != page } } ?? origins
        let archive = WebArchive(
            mainResource: .init(url: urls[0], mimeType: "text/html", data: Data(text.utf8)),
            subresources: urls.dropFirst().map { .init(url: $0, mimeType: "image/png", data: Data()) }
        )
        return WebArchiveFixtures.text(WebArchiveSeal.seal(archive).archive.mainResource.data)
    }
}
