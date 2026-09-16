import Foundation
import Testing

@testable import DirnexCore

/// What an XML tree's rows, strip and ⌘C say — the attribute rows the user chose, an element's summary,
/// its path, its source — and which elements open as it is shown.
@Suite("XMLTree as a tree")
struct XMLTreeTextTests {
    static let manifest = """
    <xamarin-android sdk-version="0.0.0" generated-on="Mon">
    \t<platform-tools revision="34.0.3" path="platform-tools">
    \t\t<urls>
    \t\t\t<url host-os="macosx" size="11215824">https://dl.google.com/a-darwin.zip</url>
    \t\t\t<url host-os="linux">https://dl.google.com/a-linux.zip</url>
    \t\t</urls>
    \t\t<empty/>
    \t\t<flags on="yes"/>
    \t</platform-tools>
    </xamarin-android>
    """

    private func tree(_ text: String = manifest) throws -> XMLTree {
        try #require(XMLTree.parse(text))
    }

    /// Every row under `node`, depth first, as `key value` — the text its two cells draw.
    private func drawn(_ tree: XMLTree, from values: [Int]) -> [String] {
        values.flatMap { value in
            ["\(tree.keyLabel(of: value).text) \(tree.valueLabel(of: value).text)"]
                + drawn(tree, from: tree.children(of: value))
        }
    }

    @Test(
        "attributes are @ rows in quotes, a leaf shows its text, and a closed element its attributes"
    )
    func rows() throws {
        let parsed = try tree()
        #expect(parsed.labelNoun == .name)
        #expect(parsed.topLevelValues == parsed.roots)
        #expect(drawn(parsed, from: parsed.topLevelValues) == [
            #"xamarin-android sdk-version="0.0.0" generated-on="Mon""#,
            #"@sdk-version "0.0.0""#,
            #"@generated-on "Mon""#,
            #"platform-tools revision="34.0.3" path="platform-tools""#,
            #"@revision "34.0.3""#,
            #"@path "platform-tools""#,
            "urls ‹2›",
            "url https://dl.google.com/a-darwin.zip",
            #"@host-os "macosx""#,
            #"@size "11215824""#,
            "url https://dl.google.com/a-linux.zip",
            #"@host-os "linux""#,
            "empty ",
            #"flags on="yes""#,
            #"@on "yes""#
        ])
    }

    @Test("each label says what kind of text it is, and which part of it a filter reads")
    func roles() throws {
        let parsed = try tree()
        let tools = parsed.child(2, of: parsed.roots[0])
        let revision = parsed.child(0, of: tools)
        let key = parsed.keyLabel(of: revision)
        #expect(key.role == .name)
        #expect(key.searched.map { String(key.text[$0]) } == "revision")
        let value = parsed.valueLabel(of: revision)
        #expect(value.role == .string)
        #expect(value.searched.map { String(value.text[$0]) } == "34.0.3")
        #expect(parsed.valueLabel(of: tools).role == .annotation)
        #expect(parsed.valueLabel(of: tools).searched == nil)
        let url = parsed.child(0, of: parsed.child(2, of: tools))
        #expect(parsed.valueLabel(of: url).role == .text)

        let mixed = try #require(XMLTree.parse("<p>a <b/> c</p>"))
        let text = mixed.child(0, of: mixed.roots[0])
        #expect(mixed.keyLabel(of: text) == TreeLabel("#text", role: .annotation))
        #expect(mixed.valueLabel(of: text) == .searched("a", role: .text))
    }

    @Test("a long summary or value is cut to what a cell shows")
    func cellLimit() throws {
        let long = String(repeating: "x", count: 2000)
        let parsed = try #require(XMLTree.parse("<r a=\"\(long)\"><b>\(long)</b></r>"))
        let summary = parsed.valueLabel(of: parsed.roots[0]).text
        #expect(summary.hasSuffix("…"))
        #expect(summary.utf8.count == TreeLabel.cellTextLimit + "…".utf8.count)
        let leaf = parsed.valueLabel(of: parsed.child(1, of: parsed.roots[0])).text
        #expect(leaf.utf8.count == TreeLabel.cellTextLimit)
    }

    @Test("a count of rows, with an ellipsis where the read limit cut the element")
    func counts() throws {
        let parsed = try #require(XMLTree.parse("<r><a/><b/><c/", isTruncated: true))
        #expect(parsed.valueLabel(of: parsed.roots[0]).text == "‹2…›")
    }

    @Test("paths are XPaths: an index where a name repeats, @ for an attribute, text() for text")
    func paths() throws {
        let parsed = try tree()
        let root = parsed.roots[0]
        let tools = parsed.child(2, of: root)
        let urls = parsed.child(2, of: tools)
        #expect(parsed.path(of: root) == "/xamarin-android")
        #expect(
            parsed.path(of: parsed.child(3, of: tools)) == "/xamarin-android/platform-tools/empty"
        )
        #expect(parsed.path(of: parsed.child(1, of: urls))
            == "/xamarin-android/platform-tools/urls/url[2]")
        #expect(parsed.path(of: parsed.child(0, of: parsed.child(0, of: urls)))
            == "/xamarin-android/platform-tools/urls/url[1]/@host-os")

        let mixed = try #require(XMLTree.parse("<p>a<b/>c<b/></p>"))
        let paragraph = mixed.roots[0]
        #expect(mixed.path(of: mixed.child(2, of: paragraph)) == "/p/text()[2]")
        let single = try #require(XMLTree.parse("<p>a<b/></p>"))
        #expect(single.path(of: single.child(0, of: single.roots[0])) == "/p/text()")
    }

    @Test(
        "the strip and ⌘C read a value as text, and an element as its source taken back to its indent"
    )
    func stripAndCopy() throws {
        let parsed = try tree()
        let tools = parsed.child(2, of: parsed.roots[0])
        let urls = parsed.child(2, of: tools)
        let url = parsed.child(0, of: urls)
        #expect(parsed.copiedText(of: url) == "https://dl.google.com/a-darwin.zip")
        #expect(parsed.copiedText(of: parsed.child(1, of: url)) == "11215824")
        #expect(parsed.copiedText(of: urls) == """
        <urls>
        \t<url host-os="macosx" size="11215824">https://dl.google.com/a-darwin.zip</url>
        \t<url host-os="linux">https://dl.google.com/a-linux.zip</url>
        </urls>
        """)
        #expect(parsed.copiedText(of: parsed.child(4, of: tools)) == #"<flags on="yes"/>"#)
        #expect(parsed.stripText(of: urls, byteLimit: 6) == "<urls>…")
        #expect(parsed.stripText(of: url, byteLimit: 5) == "https…")
        #expect(parsed.stripText(of: url, byteLimit: 1000) == "https://dl.google.com/a-darwin.zip")
    }

    @Test(
        "elements holding elements open as the tree is shown, and one whose rows are attributes does not"
    )
    func opensOnArrival() throws {
        let parsed = try tree()
        let root = parsed.roots[0]
        let tools = parsed.child(2, of: root)
        let urls = parsed.child(2, of: tools)
        #expect(parsed.initialExpansion(rowBudget: 200) == [root, tools, urls])
        #expect(parsed.initialExpansion(rowBudget: 4) == [root])
    }
}
