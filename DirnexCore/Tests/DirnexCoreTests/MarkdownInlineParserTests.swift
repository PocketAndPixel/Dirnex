import Foundation
import Testing

@testable import DirnexCore

/// The inline pass (PLAN.md §M18 ▸ Slice 1).
///
/// Emphasis carries most of the risk, and one case carries most of *that*: `*a **b** c*` is why the
/// scan and the pairing are two passes rather than one, so it has a test of its own with the reason
/// written next to it.
@Suite("MarkdownInlineParser")
struct MarkdownInlineParserTests {
    private func parse(
        _ text: String,
        references: [String: MarkdownLinkReference] = [:]
    ) -> [MarkdownInline] {
        MarkdownInlineParser.parse(text, references: references)
    }

    // MARK: - Text and escapes

    @Test("plain text is one node, not one per character")
    func plainText() {
        #expect(parse("just words") == [.text("just words")])
    }

    @Test("a backslash escapes ASCII punctuation and nothing else")
    func escapes() {
        #expect(parse("\\*not emphasis\\*") == [.text("*not emphasis*")])
        // `\n` in a Markdown file is two characters. Rewriting it would eat every Windows path.
        #expect(parse("C:\\new\\table") == [.text("C:\\new\\table")])
    }

    // MARK: - Code spans

    @Test("a code span closes on a backtick run of its own length")
    func codeSpans() {
        #expect(parse("a `b` c") == [.text("a "), .code("b"), .text(" c")])
        #expect(parse("``a `b` c``") == [.code("a `b` c")])
    }

    @Test("one space is stripped from each end, which is how a code span holds a backtick")
    func codeSpanPadding() {
        #expect(parse("`` ` ``") == [.code("`")])
        #expect(parse("` a `") == [.code("a")])
    }

    @Test("an unclosed backtick run is literal text")
    func unclosedCodeSpan() {
        #expect(parse("a ` b") == [.text("a ` b")])
    }

    @Test("no inline construct is read inside a code span")
    func codeSpanIsLiteral() {
        #expect(parse("`*not em* [not a link](x)`") == [.code("*not em* [not a link](x)")])
    }

    // MARK: - Emphasis

    @Test("one delimiter is emphasis, two are strong, three are both")
    func emphasisLevels() {
        #expect(parse("*a*") == [.emphasis([.text("a")])])
        #expect(parse("**a**") == [.strong([.text("a")])])
        #expect(parse("***a***") == [.emphasis([.strong([.text("a")])])])
    }

    @Test("strong inside emphasis resolves both, which one forward scan cannot do")
    func nestedEmphasis() {
        // The case the two-pass design exists for: scanning forward from the first `*`, the `**`
        // after `b` is a legal closer, so a greedy match ends the emphasis inside the strong one
        // and the rest of the line comes out as literal asterisks.
        #expect(parse("*a **b** c*") == [.emphasis([
            .text("a "),
            .strong([.text("b")]),
            .text(" c")
        ])])
    }

    @Test("an intraword underscore is text, and an intraword asterisk is emphasis")
    func underscoreFlanking() {
        // `report_2026_final.pdf` and `my_variable_name` are things people write.
        #expect(parse("report_2026_final.pdf") == [.text("report_2026_final.pdf")])
        #expect(parse("a*b*c") == [.text("a"), .emphasis([.text("b")]), .text("c")])
        #expect(parse("_emphasis_") == [.emphasis([.text("emphasis")])])
    }

    @Test("a delimiter that pairs with nothing comes back as the character it was")
    func strandedDelimiters() {
        // The guarantee that keeps a misparse from ever being a *lost* character (PLAN.md §6).
        #expect(parse("2 * 3 * 4") == [.text("2 * 3 * 4")])
        #expect(parse("*unclosed") == [.text("*unclosed")])
        #expect(parse("a ** b") == [.text("a ** b")])
    }

    @Test("strikethrough needs exactly two tildes")
    func strikethrough() {
        #expect(parse("~~gone~~") == [.strikethrough([.text("gone")])])
        // One tilde is punctuation — an approximation, or a home directory.
        #expect(parse("~/Documents") == [.text("~/Documents")])
        #expect(parse("a ~ b") == [.text("a ~ b")])
    }

    // MARK: - Links and images

    @Test("an inline link takes its destination and its optional title")
    func inlineLinks() {
        #expect(parse("[text](https://example.com)") == [.link(
            destination: "https://example.com",
            title: nil,
            children: [.text("text")]
        )])
        #expect(parse("[text](https://example.com \"Title\")") == [.link(
            destination: "https://example.com",
            title: "Title",
            children: [.text("text")]
        )])
    }

    @Test("a link's text is parsed, and a destination in angle brackets may hold a space")
    func linkContents() {
        #expect(parse("[**bold**](</a b>)") == [.link(
            destination: "/a b",
            title: nil,
            children: [.strong([.text("bold")])]
        )])
    }

    @Test("all three reference forms resolve against the definitions")
    func referenceLinks() {
        let references = ["home": MarkdownLinkReference(destination: "/home", title: nil)]
        let expected: [MarkdownInline] = [.link(
            destination: "/home",
            title: nil,
            children: [.text("Home")]
        )]
        #expect(parse("[Home][home]", references: references) == expected)
        #expect(parse("[Home][]", references: references) == expected)
        // The shortcut form, and the case-folded match that makes a definition findable at all.
        #expect(parse("[Home]", references: references) == expected)
    }

    @Test("a reference with no definition keeps its brackets and its contents")
    func unresolvedReference() {
        #expect(parse("[see *note*]") == [
            .text("[see "),
            .emphasis([.text("note")]),
            .text("]")
        ])
    }

    @Test("an image's alt text is flattened, since markup cannot be drawn in an attribute")
    func images() {
        #expect(parse("![a *picture*](img/x.png)") == [.image(
            source: "img/x.png",
            title: nil,
            alt: "a picture"
        )])
    }

    @Test("a bang that is not a link is a bang")
    func loneBang() {
        #expect(parse("Hello! World") == [.text("Hello! World")])
    }

    // MARK: - Autolinks and entities

    @Test("angle brackets hold a URL or an address, and everything else is text")
    func autolinks() {
        #expect(parse("<https://example.com>") == [.link(
            destination: "https://example.com",
            title: nil,
            children: [.text("https://example.com")]
        )])
        #expect(parse("<a@example.com>") == [.link(
            destination: "mailto:a@example.com",
            title: nil,
            children: [.text("a@example.com")]
        )])
        // Raw HTML is text in this renderer, which is what keeps the generated page inert.
        #expect(parse("<div class=\"x\">") == [.text("<div class=\"x\">")])
        #expect(parse("a < b and c > d") == [.text("a < b and c > d")])
    }

    @Test("entities are decoded to the character they name, so the renderer escapes uniformly")
    func entities() {
        #expect(parse("a &amp; b") == [.text("a & b")])
        #expect(parse("&#65;&#x42;") == [.text("AB")])
        #expect(parse("&mdash;") == [.text("—")])
        // An unknown name stays exactly as written.
        #expect(parse("&notanentity;") == [.text("&notanentity;")])
        #expect(parse("Tom & Jerry") == [.text("Tom & Jerry")])
    }

    // MARK: - Breaks

    @Test("two trailing spaces are a hard break, and a bare newline is a soft one")
    func breaks() {
        #expect(parse("a  \nb") == [.text("a"), .lineBreak, .text("b")])
        #expect(parse("a\\\nb") == [.text("a"), .lineBreak, .text("b")])
        #expect(parse("a\nb") == [.text("a"), .softBreak, .text("b")])
    }
}
