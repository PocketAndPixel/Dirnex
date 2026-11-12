import Foundation
import Testing

@testable import DirnexCore

@Suite("MHTMLArchive")
struct MHTMLArchiveTests {
    private static let origin = WebArchiveFixtures.origin
    private static let frameCID = "cid:frame-5F5CF8022664EC61DBF8FF30DE047FC7@mhtml.blink"
    private static let styleCID = "cid:css-0fdf9d14-d4b8-4d75-bcae-7502d4c86e83@mhtml.blink"

    @Test("Chrome's page becomes a page and its two subresources, under the URLs they came from")
    func convertsChromePage() throws {
        let archive = try MHTMLArchive.webArchive(from: WebArchiveFixtures.data("chrome-page.mhtml"))
        #expect(archive.mainResource.url == Self.origin + "/index.html")
        #expect(archive.mainResource.mimeType == "text/html")
        // Chrome names no charset; the page's own `<meta>` does, and WebKit honours it.
        #expect(archive.mainResource.textEncodingName == nil)
        #expect(WebArchiveFixtures.text(archive.mainResource.data).contains("Héllo archive"))
        #expect(
            archive.subresources.map(\.url) == [Self.origin + "/red.png", Self.origin + "/style.css"]
        )
        #expect(archive.subresources[0].data == (try WebArchiveFixtures.png()))
        #expect(archive.subframes.isEmpty)
        #expect(archive.frameName.isEmpty)
    }

    @Test(
        "a windows-1252 page keeps its bytes, and its iframe becomes frame 1 under the cid it is named by"
    )
    func convertsChromeFrames() throws {
        let archive = try MHTMLArchive.webArchive(
            from: WebArchiveFixtures.data("chrome-frames.mhtml")
        )
        #expect(archive.mainResource.url == Self.origin + "/outer.html")
        #expect(archive.mainResource.data.range(of: Data("caf\u{E9}".utf8)) == nil)
        #expect(archive.mainResource.data.range(of: Data([0x63, 0x61, 0x66, 0xE9])) != nil)

        let frame = try #require(archive.subframes.first)
        #expect(archive.subframes.count == 1)
        #expect(frame.frameName == "<!--frame1-->")
        #expect(frame.mainResource.url == Self.frameCID)
        #expect(
            WebArchiveFixtures.text(frame.mainResource.data).contains("Inner frame ünïcode")
        )
        // What the frame's text names, and nothing it does not: the spaced image is the page's.
        #expect(Set(frame.subresources.map(\.url)) == [Self.origin + "/red.png", Self.styleCID])
        #expect(Set(archive.subresources.map(\.url)) == [
            Self.origin + "/dir%20with%20space/r%20%C3%A9%20d.png", Self.origin + "/red.png",
            Self.styleCID
        ])
    }

    @Test("a part with both a Content-ID and a Content-Location is in the archive under each")
    func bothNames() throws {
        let archive = try Self.convert("""
        Content-Type: multipart/related; boundary=b

        --b
        Content-Type: text/html
        Content-Location: http://a.example/

        <img src="cid:pic"><img src="http://a.example/pic.png">
        --b
        Content-Type: image/png
        Content-ID: <pic>
        Content-Location: http://a.example/pic.png

        PNG
        --b--
        """)
        #expect(archive.subresources.map(\.url) == ["cid:pic", "http://a.example/pic.png"])
    }

    @Test("the start parameter names the page, before file order")
    func startNamesThePage() throws {
        let archive = try Self.convert("""
        Content-Type: multipart/related; boundary=b; start="<second>"

        --b
        Content-Type: text/html
        Content-ID: <first>

        <p>frame</p>
        --b
        Content-Type: text/html
        Content-ID: <second>
        Content-Location: http://a.example/page.html

        <iframe src="cid:first"></iframe>
        --b--
        """)
        #expect(archive.mainResource.url == "http://a.example/page.html")
        #expect(archive.subframes.map(\.mainResource.url) == ["cid:first"])
    }

    @Test("when the first part is not a page, the first HTML part is")
    func firstHTMLPart() throws {
        let archive = try Self.convert("""
        Content-Type: multipart/related; boundary=b

        --b
        Content-Type: image/png
        Content-Location: http://a.example/x.png

        PNG
        --b
        Content-Type: text/html; charset=iso-8859-1
        Content-Location: http://a.example/

        <p>page</p>
        --b--
        """)
        #expect(archive.mainResource.url == "http://a.example/")
        #expect(archive.mainResource.textEncodingName == "iso-8859-1")
        #expect(archive.subresources.map(\.url) == ["http://a.example/x.png"])
    }

    @Test("frames are numbered in the order the page names them, not the order the file holds them")
    func framesInReferenceOrder() throws {
        let archive = try Self.convert("""
        Content-Type: multipart/related; boundary=b

        --b
        Content-Type: text/html
        Content-Location: http://a.example/

        <iframe src="cid:one"></iframe><iframe src="http://a.example/two.html"></iframe>
        --b
        Content-Type: text/html
        Content-Location: http://a.example/two.html

        two
        --b
        Content-Type: text/html
        Content-ID: <unnamed>

        never named
        --b
        Content-Type: text/html
        Content-ID: <one>

        one
        --b--
        """)
        #expect(
            archive.subframes.map(\.mainResource.url) == [
                "cid:one",
                "http://a.example/two.html",
                "cid:unnamed"
            ]
        )
        #expect(
            archive.subframes.map(\.frameName) == ["<!--frame1-->", "<!--frame2-->", "<!--frame3-->"]
        )
    }

    @Test("a frame takes what its stylesheet names, not only what it names itself")
    func frameResourcesTransitive() throws {
        let archive = try Self.convert("""
        Content-Type: multipart/related; boundary=b

        --b
        Content-Type: text/html
        Content-Location: http://a.example/

        <iframe src="cid:f"></iframe>
        --b
        Content-Type: text/html
        Content-ID: <f>

        <link rel=stylesheet href="http://a.example/s.css">
        --b
        Content-Type: text/css
        Content-Location: http://a.example/s.css

        body { background: url(http://a.example/bg.png) }
        --b
        Content-Type: image/png
        Content-Location: http://a.example/bg.png

        PNG
        --b
        Content-Type: image/png
        Content-Location: http://a.example/unused.png

        PNG
        --b--
        """)
        let frame = try #require(archive.subframes.first)
        #expect(
            frame.subresources.map(\.url) == ["http://a.example/s.css", "http://a.example/bg.png"]
        )
    }

    @Test("a relative Content-Location resolves against the message's own location")
    func relativeLocation() throws {
        let archive = try Self.convert("""
        Content-Type: multipart/related; boundary=b
        Content-Location: http://a.example/dir/page.html

        --b
        Content-Type: text/html
        Content-Location: page.html

        <img src="img/x.png">
        --b
        Content-Type: image/png
        Content-Location: img/x.png

        PNG
        --b--
        """)
        #expect(archive.mainResource.url == "http://a.example/dir/page.html")
        #expect(archive.subresources.map(\.url) == ["http://a.example/dir/img/x.png"])
    }

    @Test("a single HTML entity is a page with nothing else")
    func singlePart() throws {
        let archive = try Self.convert(
            "Content-Type: text/html\nContent-Location: http://a.example/\n\n<p>hi</p>"
        )
        #expect(archive.mainResource.url == "http://a.example/")
        #expect(archive.mainResource.data == Data("<p>hi</p>".utf8))
    }

    @Test("no HTML part, or no MIME at all, is no page")
    func noPage() {
        #expect(throws: MHTMLArchive.Failure.noPage) {
            try Self.convert(
                "Content-Type: multipart/related; boundary=b\n\n--b\nContent-Type: image/png\n\nPNG\n--b--"
            )
        }
        #expect(throws: MHTMLArchive.Failure.noPage) {
            try MHTMLArchive.webArchive(from: Data("just text".utf8))
        }
    }

    private static func convert(_ text: String) throws -> WebArchive {
        try MHTMLArchive.webArchive(from: Data(text.utf8))
    }
}
