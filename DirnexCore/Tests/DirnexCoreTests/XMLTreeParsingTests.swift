import Foundation
import Testing

@testable import DirnexCore

/// Reading XML into elements, attributes and text — what Foundation's parsers get wrong for a preview,
/// the rows a tree lists, the normalization every reader owes, and a file cut at the read limit.
@Suite("XMLTree parsing")
struct XMLTreeParsingTests {
    private func tree(_ text: String, isTruncated: Bool = false) throws -> XMLTree {
        try #require(XMLTree.parse(text, isTruncated: isTruncated))
    }

    /// Each row under `node`: `@name=value` for an attribute, `name` for an element, `#text=text`.
    private func rows(_ tree: XMLTree, of node: Int) -> [String] {
        tree.children(of: node).map { row in
            switch tree.kind(of: row) {
            case .attribute: "@\(tree.name(of: row))=\(tree.attributeValue(of: row))"
            case .element: tree.name(of: row)
            case .text: "#text=\(tree.trimmedText(of: row))"
            }
        }
    }

    // MARK: - Structure

    /// What `XMLParser` returned for these attributes on three runs, measured before any of this was
    /// written: three different orders.
    @Test("attributes keep the order the file writes them in")
    func attributeOrder() throws {
        let parsed = try tree(#"<r zeta="1" alpha="2" mid="3" beta="4" gamma="5"/>"#)
        #expect(
            rows(parsed, of: parsed.roots[0]) == [
                "@zeta=1",
                "@alpha=2",
                "@mid=3",
                "@beta=4",
                "@gamma=5"
            ]
        )
    }

    @Test(
        "an element lists its attributes, then its elements; a leaf's text is its value, not a row"
    )
    func rowsOfAnElement() throws {
        let parsed = try tree("""
        <?xml version="1.0" encoding="utf-8"?>
        <Project Sdk="Microsoft.NET.Sdk">
          <PropertyGroup>
            <TargetFramework>net8.0</TargetFramework>
            <Nullable>enable</Nullable>
          </PropertyGroup>
          <ItemGroup>
            <PackageReference Include="Serilog" Version="3.1.1" />
          </ItemGroup>
        </Project>
        """)
        let project = try #require(parsed.roots.first)
        #expect(parsed.name(of: project) == "Project")
        #expect(
            rows(parsed, of: project) == ["@Sdk=Microsoft.NET.Sdk", "PropertyGroup", "ItemGroup"]
        )
        let group = parsed.child(1, of: project)
        #expect(rows(parsed, of: group) == ["TargetFramework", "Nullable"])
        let framework = parsed.child(0, of: group)
        #expect(parsed.childCount(of: framework) == 0)
        #expect(!parsed.hasElementChildren(framework))
        #expect(parsed.text(of: framework) == "net8.0")
        let reference = parsed.child(0, of: parsed.child(2, of: project))
        #expect(rows(parsed, of: reference) == ["@Include=Serilog", "@Version=3.1.1"])
        #expect(parsed.parent(of: reference) == parsed.child(2, of: project))
        #expect(parsed.parent(of: project) == nil)
        #expect(parsed.nodeCount == 9)
    }

    @Test(
        "text beside elements is rows in the file's order, and the indentation between them is not"
    )
    func mixedContent() throws {
        let parsed = try tree("""
        <summary>
          Gets the <see cref="T:Name"/> of the <paramref name="x"/>.
        </summary>
        """)
        let summary = try #require(parsed.roots.first)
        #expect(parsed.hasElementChildren(summary))
        #expect(
            rows(parsed, of: summary) == [
                "#text=Gets the",
                "see",
                "#text=of the",
                "paramref",
                "#text=."
            ]
        )
        #expect(parsed.content(of: summary).map { parsed.kind(of: $0) } == [
            .text, .element, .text, .element, .text
        ])
    }

    @Test(
        "comments, processing instructions and the document type, internal subset and all, are skipped"
    )
    func skipsWhatIsNotContent() throws {
        let parsed = try tree("""
        <?xml version="1.0"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" [ <!ENTITY a "x>y"> ]>
        <!-- before -->
        <root><!-- a comment with <tags> --><?pi data?><a>1</a><!-- after --></root>
        <!-- trailing -->
        """)
        let root = try #require(parsed.roots.first)
        #expect(parsed.roots.count == 1)
        #expect(rows(parsed, of: root) == ["a"])
    }

    @Test("several elements at the top are several roots")
    func severalRoots() throws {
        let parsed = try tree("<a>1</a>\n<b x=\"2\"/>\n")
        #expect(parsed.roots.map { parsed.name(of: $0) } == ["a", "b"])
    }

    @Test(
        "names keep their prefix, and text outside ASCII passes through names and values unchanged"
    )
    func namesAndUnicode() throws {
        let parsed = try tree(#"<sdk:ключ xmlns:sdk="urn:x" имя="Панорама 東京">значение</sdk:ключ>"#)
        let root = try #require(parsed.roots.first)
        #expect(parsed.name(of: root) == "sdk:ключ")
        #expect(rows(parsed, of: root) == ["@xmlns:sdk=urn:x", "@имя=Панорама 東京"])
        #expect(parsed.text(of: root) == "значение")
    }

    @Test("a byte-order mark before the declaration is not text outside the root")
    func byteOrderMark() throws {
        let parsed = try tree("\u{FEFF}<?xml version=\"1.0\"?><a/>")
        #expect(parsed.roots.count == 1)
    }

    // MARK: - Text

    @Test("the predefined entities and character references are read, and any other entity is kept")
    func references() throws {
        let parsed = try tree(
            #"<a v="&lt;&amp;&gt;&quot;&apos;">x &#233; &#x1F600; &nbsp; &#xD800; &broken y</a>"#
        )
        let root = try #require(parsed.roots.first)
        #expect(!parsed.sourceText(of: root).contains("é"))
        #expect(parsed.attributeValue(of: parsed.child(0, of: root)) == #"<&>"'"#)
        #expect(parsed.text(of: root) == "x é 😀 &nbsp; \u{FFFD} &broken y")
    }

    @Test("CDATA is text as written, references and markup inside it included")
    func characterData() throws {
        let parsed = try tree("<a><![CDATA[<b>&amp;</b>]]> and &amp;</a>")
        #expect(parsed.text(of: parsed.roots[0]) == "<b>&amp;</b> and &")

        let mixed = try tree("<a><b/><![CDATA[x < y]]></a>")
        let cdata = mixed.child(1, of: mixed.roots[0])
        #expect(mixed.kind(of: cdata) == .text)
        #expect(mixed.text(of: cdata) == "x < y")
    }

    /// The normalization a reader owes, which 44 files on this Mac differed from `expat` by until it
    /// was done.
    @Test("a carriage return reads as a line feed, and whitespace in an attribute value as spaces")
    func lineBreaks() throws {
        let parsed = try tree("<a d=\"M1,2\r\n\tL3,4\n5\">one\r\ntwo\rthree<!-- c -->\r\n</a>")
        let root = try #require(parsed.roots.first)
        #expect(parsed.attributeValue(of: parsed.child(0, of: root)) == "M1,2  L3,4 5")
        #expect(parsed.text(of: root) == "one\ntwo\nthree\n")
        #expect(parsed.trimmedText(of: root) == "one\ntwo\nthree")

        let referenced = try tree("<a b=\"x&#10;y\"/>")
        #expect(
            referenced.attributeValue(of: referenced.child(0, of: referenced.roots[0])) == "x\ny"
        )
    }

    @Test("trimming takes XML's whitespace off, and keeps a no-break or zero-width space")
    func trimming() throws {
        let parsed = try tree("<a>\n  \u{00A0}x\u{200B}\t\n</a>")
        #expect(parsed.trimmedText(of: parsed.roots[0]) == "\u{00A0}x\u{200B}")
    }

    // MARK: - Refusals

    @Test("what is not XML this reads is refused, so the file is shown as its text")
    func refusals() {
        let refused = [
            "", "   ", "plain text", "[section]\nkey=value\n", "<a></b>", "<a>", "<a><b></a></b>",
            "<a/> trailing text", "text <a/>", "<html><br></html>", "<a b=1/>", "<a b=\"1></a>",
            "<!-- only a comment -->", "<a><!-- unclosed</a>", "<![CDATA[x]]>",
            "<a><!DOCTYPE x></a>"
        ]
        for text in refused {
            #expect(XMLTree.parse(text) == nil, "\(text.debugDescription) should be refused")
        }
    }

    @Test("past the node limit the file is refused rather than built part-way")
    func nodeLimit() {
        let text = "<r>" + String(repeating: "<a/>", count: 10) + "</r>"
        #expect(XMLTree.parse(text, isTruncated: false, nodeLimit: 11) != nil)
        #expect(XMLTree.parse(text, isTruncated: false, nodeLimit: 10) == nil)
    }

    @Test("nesting deeper than a thread's stack reads, since the scan keeps a stack of its own")
    func deepNesting() throws {
        let depth = 100_000
        let text = String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)
        let parsed = try tree(text)
        #expect(parsed.nodeCount == depth)
    }

    // MARK: - Truncation

    @Test(
        "a file cut at the read limit closes what is open, marked, and leaves out the tag it split"
    )
    func truncation() throws {
        let text = "<root>\n  <item id=\"1\">one</item>\n  <item id=\"2\">two</item>\n  <item id=\"3"
        #expect(XMLTree.parse(text) == nil)
        let parsed = try tree(text, isTruncated: true)
        let root = try #require(parsed.roots.first)
        #expect(parsed.isTruncated)
        #expect(parsed.isIncomplete(root))
        #expect(rows(parsed, of: root) == ["item", "item"])
        #expect(!parsed.isIncomplete(parsed.child(0, of: root)))
        #expect(parsed.sourceText(of: root).hasSuffix("two</item>\n  "))
    }

    @Test("a cut inside a leaf's text keeps the text read so far, and the leaf is incomplete")
    func truncatedLeaf() throws {
        let parsed = try tree("<r><note>a long no", isTruncated: true)
        let note = parsed.child(0, of: parsed.roots[0])
        #expect(parsed.isIncomplete(note))
        #expect(parsed.text(of: note) == "a long no")
    }
}
