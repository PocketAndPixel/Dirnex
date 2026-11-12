import Foundation
import Testing

@testable import DirnexCore

@Suite("MIMEEntity")
struct MIMEEntityTests {
    // MARK: - Chrome's file

    @Test("Chrome's page reads as a related multipart of three parts")
    func readsChromePage() throws {
        let entity = try #require(MIMEEntity(parsing: WebArchiveFixtures.data("chrome-page.mhtml")))
        #expect(
            entity.header("snapshot-content-location") == WebArchiveFixtures.origin + "/index.html"
        )
        // Folded over three lines in the file, with tabs.
        let type = entity.contentType
        #expect(type.type == "multipart/related")
        #expect(type.parameter("type") == "text/html")
        #expect(type.parameter("BOUNDARY")?.hasPrefix("----MultipartBoundary--") == true)
        #expect(entity.leaves.map(\.contentType.type) == ["text/html", "image/png", "text/css"])
        #expect(entity.leaves.map { $0.header("Content-Location") } == [
            WebArchiveFixtures.origin + "/index.html",
            WebArchiveFixtures.origin + "/red.png",
            WebArchiveFixtures.origin + "/style.css"
        ])
    }

    @Test("quoted-printable HTML and a base64 image decode to their real bytes")
    func decodesChromeBodies() throws {
        let entity = try #require(MIMEEntity(parsing: WebArchiveFixtures.data("chrome-page.mhtml")))
        let html = WebArchiveFixtures.text(entity.leaves[0].body)
        #expect(html.contains("<h1 id=\"h\">Héllo archive</h1>"))
        #expect(html.contains("href=\"http://127.0.0.1:8765/style.css\""))
        #expect(!html.contains("=3D"))
        // The same PNG, captured independently by WebKit.
        #expect(entity.leaves[1].body == (try WebArchiveFixtures.png()))
        // Chrome writes a stylesheet as it parsed it, not as the server sent it.
        let css = WebArchiveFixtures.text(entity.leaves[2].body)
        #expect(css.hasPrefix("@charset \"utf-8\";"))
        #expect(css.contains(".box { width: 300px; height: 40px; background: rgb(0, 0, 255); }"))
    }

    @Test("the same file with LF line endings reads the same")
    func acceptsLineFeedsAlone() throws {
        let crlf = try WebArchiveFixtures.data("chrome-page.mhtml")
        let lf = Data(Self.lineFeeds(WebArchiveFixtures.text(crlf)).utf8)
        let one = try #require(MIMEEntity(parsing: crlf))
        let other = try #require(MIMEEntity(parsing: lf))
        #expect(one.leaves.map(\.contentType) == other.leaves.map(\.contentType))
        // The line breaks *inside* a text body are content, and changed with the file's. The PNG is
        // compared as bytes: its own signature holds a CRLF.
        for index in [0, 2] {
            #expect(Self.lineFeeds(WebArchiveFixtures.text(one.leaves[index].body))
                == WebArchiveFixtures.text(other.leaves[index].body))
        }
        #expect(one.leaves[1].body == other.leaves[1].body)
    }

    private static func lineFeeds(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    // MARK: - Multipart

    @Test("preamble and epilogue are not parts, and the line before a delimiter belongs to it")
    func splitsParts() throws {
        let entity = try Self.parse("""
        Content-Type: multipart/mixed; boundary=XyZ

        preamble text
        --XyZ
        Content-Type: text/plain

        first line
        second line
        --XyZ \t
        Content-Type: text/plain

        two
        --XyZ--
        epilogue
        """)
        #expect(entity.parts.count == 2)
        #expect(
            entity.leaves.map { WebArchiveFixtures.text($0.body) } == [
                "first line\nsecond line",
                "two"
            ]
        )
    }

    @Test("a line that only starts with the boundary is body text, not a delimiter")
    func boundaryPrefixIsText() throws {
        let entity = try Self.parse("""
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain

        --bogus line
        --b--
        """)
        #expect(entity.leaves.map { WebArchiveFixtures.text($0.body) } == ["--bogus line"])
    }

    @Test("a body with no closing delimiter keeps its last part")
    func unclosedMultipart() throws {
        let entity = try Self.parse("""
        Content-Type: multipart/mixed; boundary=b

        --b
        Content-Type: text/plain

        last
        """)
        #expect(entity.leaves.map { WebArchiveFixtures.text($0.body) } == ["last"])
    }

    @Test("a multipart inside a multipart flattens into leaves")
    func nestedMultipart() throws {
        let entity = try Self.parse("""
        Content-Type: multipart/related; boundary=outer

        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain

        plain
        --inner
        Content-Type: text/html

        <p>html</p>
        --inner--
        --outer
        Content-Type: image/png
        Content-Transfer-Encoding: base64

        iVBORw==
        --outer--
        """)
        #expect(entity.leaves.map(\.contentType.type) == ["text/plain", "text/html", "image/png"])
    }

    @Test("data with no end to its headers is not MIME")
    func notMIME() {
        #expect(MIMEEntity(parsing: Data("<html><body>no headers".utf8)) == nil)
        #expect(MIMEEntity(parsing: Data()) == nil)
    }

    @Test("a header folded onto the next line is one header")
    func unfoldsHeaders() throws {
        let entity = try Self.parse("Subject: one\n two\n\tthree\nX-Other: yes\n\nbody")
        #expect(entity.header("subject") == "one two three")
        #expect(entity.header("X-OTHER") == "yes")
        #expect(entity.body == Data("body".utf8))
    }

    // MARK: - Transfer encodings

    @Test("quoted-printable: escapes, soft breaks of both kinds, and a stray equals sign")
    func quotedPrintable() {
        let decoded = MIMEEntity.decodeQuotedPrintable(Array("a=3Db=\r\nc=\nd=ZZ=e9=".utf8))
        #expect([UInt8](decoded) == Array("a=bcd=ZZ".utf8) + [0xE9, UInt8(ascii: "=")])
    }

    @Test("base64 ignores what is not in its alphabet and restores the padding")
    func base64() {
        #expect(MIMEEntity.decodeBase64(Array("aGVs\r\nbG8 \t!".utf8)) == Data("hello".utf8))
        #expect(MIMEEntity.decodeBase64(Array("aGVsbG8".utf8)) == Data("hello".utf8))
        #expect(MIMEEntity.decodeBase64(Array("aGVsbG8hZ".utf8)) == Data("hello!".utf8))
    }

    @Test("an unknown transfer encoding leaves the bytes as they are")
    func unknownEncoding() {
        #expect(
            MIMEEntity.decode(Array("x=41".utf8), transferEncoding: "x-uuencode") == Data(
                "x=41".utf8
            )
        )
        #expect(
            MIMEEntity.decode(Array("x=41".utf8), transferEncoding: " Quoted-Printable ") == Data(
                "xA".utf8
            )
        )
    }

    // MARK: - Content-Type

    @Test("parameters: quoted, with a semicolon inside, an escaped quote, names in any case")
    func contentTypeParameters() {
        let type = MIMEContentType(
            parsing: #"Text/HTML; Charset="utf-8"; boundary="a;b"; name="say \"hi\"""#
        )
        #expect(type.type == "text/html")
        #expect(type.parameter("charset") == "utf-8")
        #expect(type.parameter("boundary") == "a;b")
        #expect(type.parameter("name") == #"say "hi""#)
        #expect(!type.isMultipart)
        #expect(MIMEContentType(parsing: "multipart/related").isMultipart)
    }

    @Test("an entity with no Content-Type is text/plain, RFC 2045's default")
    func defaultContentType() throws {
        #expect(try Self.parse("X-A: b\n\nbody").contentType.type == "text/plain")
    }

    private static func parse(_ text: String) throws -> MIMEEntity {
        try #require(MIMEEntity(parsing: Data(text.utf8)))
    }
}
