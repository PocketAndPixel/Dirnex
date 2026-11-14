import Foundation
import Testing

@testable import DirnexCore

/// The Markdown constructs that need the line before (PLAN.md §M39 ▸ Slice 9): setext headings,
/// indented code, and what decides them — the open paragraph, a list item's content column, front
/// matter, and fences closed by CommonMark's rule. Each expectation is what micromark parses the
/// same text as, which is how the rules were scored over every `.md` file on this Mac.
@Suite("SyntaxMarkdown: setext headings, indented code and fences")
struct SyntaxMarkdownBlockTests {
    private typealias Span = SyntaxSpan

    private func md(_ text: String) -> [Span] { syntaxSpans(text, .markdown) }

    // MARK: - Setext headings

    @Test("text underlined with = or - is a heading, both lines of it")
    func setextHeadings() {
        #expect(md("Title\n=====\n\nSection\n---\n") == [
            Span("Title", .keyword),
            Span("=====", .keyword),
            Span("Section", .keyword),
            Span("---", .keyword)
        ])
        // One character is an underline, and trailing spaces do not spoil one.
        #expect(md("A\n=\nB\n-  \n") == [
            Span("A", .keyword),
            Span("=", .keyword),
            Span("B", .keyword),
            Span("-  ", .keyword)
        ])
    }

    @Test("every line of the paragraph is the heading, and its inline colors give way")
    func multiLineSetextHeading() {
        #expect(md("Embedded *JavaScript*\n[![badge](b.svg)](x)\n===\n") == [
            Span("Embedded *JavaScript*", .keyword),
            Span("[![badge](b.svg)](x)", .keyword),
            Span("===", .keyword)
        ])
        // A paragraph that ends without one keeps them.
        #expect(md("Plain *one*\n\n===") == [Span("*one*", .typeOrTag)])
    }

    @Test("an underline with spaces inside, or of asterisks, is a thematic break")
    func notAnUnderline() {
        #expect(md("Foo *x*\n- - -") == [Span("*x*", .typeOrTag), Span("- - -", .keyword)])
        #expect(md("Foo\n***") == [Span("***", .keyword)])
        // Four columns in, it is the paragraph's own text.
        #expect(md("Foo\n    ===").isEmpty)
    }

    @Test("a list item, a quote or a table takes no underline, so the --- below is a rule")
    func containersTakeNoUnderline() {
        #expect(md("- item\n---") == [Span("-", .number), Span("---", .keyword)])
        #expect(md("> quoted\n---") == [Span("> quoted", .comment), Span("---", .keyword)])
        // A lazy line of the quote: `===` is more of its text, not an underline.
        #expect(md("> quoted\nlazy\n===") == [Span("> quoted", .comment)])
        #expect(md("|a|b|\n|-|-|\n|1|2|\n---") == [Span("---", .keyword)])
    }

    @Test("a bare marker is an empty item, so a column of them is a list, not a heading")
    func emptyListItems() {
        #expect(md(" -\n -\n") == [Span("-", .number), Span("-", .number)])
        // …but under a paragraph an empty item cannot start, and `-` there is an underline.
        #expect(md("Foo\n-") == [Span("Foo", .keyword), Span("-", .keyword)])
    }

    @Test("an underline survives CRLF")
    func setextWindowsLineEndings() {
        #expect(md("Title\r\n===\r\n") == [Span("Title", .keyword), Span("===", .keyword)])
    }

    // MARK: - Front matter

    @Test("front matter's closing fence is a fence, not an underline under its last key")
    func frontMatter() {
        #expect(md("---\ntitle: x\nlist:\n- a\n---\n# H") == [
            Span("---", .keyword),
            Span("-", .number),
            Span("---", .keyword),
            Span("# H", .keyword)
        ])
        #expect(md("---\nname: n\n...\nText") == [
            Span("---", .keyword),
            Span("...", .keyword)
        ])
        // No `key:` first, no front matter: a rule, then a heading underlined, as the page has it.
        #expect(md("---\nSome prose\n---") == [
            Span("---", .keyword),
            Span("Some prose", .keyword),
            Span("---", .keyword)
        ])
    }

    // MARK: - Indented code

    @Test("four columns in after a blank line is code, and nothing inside it colors")
    func indentedCode() {
        #expect(md("Para\n\n    # not a heading\n    *ptr = [i];\n\n    - x *y*\nAfter *z*") == [
            Span("*z*", .typeOrTag)
        ])
        // At the top of the file, after a heading, and indented by a tab.
        #expect(md("    > not a quote").isEmpty)
        #expect(md("# H\n    # code") == [Span("# H", .keyword)])
        #expect(md("\t# code").isEmpty)
    }

    @Test("four columns under a paragraph continue it, so its inline colors stay")
    func indentedContinuation() {
        #expect(md("Para\n    # still the paragraph *x*") == [Span("*x*", .typeOrTag)])
    }

    @Test("inside a list, code needs four columns past the item's content")
    func indentedCodeInLists() {
        // The item's content starts at column 2, so column 4 is its paragraph and column 6 its code.
        #expect(md("- item\n\n    more *x*\n\n      code *y*") == [
            Span("-", .number),
            Span("*x*", .typeOrTag)
        ])
        // A nested item at column 4 stays an item.
        #expect(md("1. one\n\n    - two") == [Span("1.", .number), Span("-", .number)])
        // An unindented paragraph after a blank line closes the list, and code is four columns again.
        #expect(md("- item\n\nPara\n\n    code *z*") == [Span("-", .number)])
    }

    // MARK: - Fences

    @Test("a fence closes on a run at least as long, so ```` can show ``` inside it")
    func longerFenceHoldsShorterOnes() {
        #expect(md("````markdown\n```swift\nlet\n```\n````\n# after") == [
            Span("````markdown", .keyword),
            Span("```swift", .keyword),
            Span("let", .keyword),
            Span("```", .keyword),
            Span("````", .keyword),
            Span("# after", .keyword)
        ])
    }

    @Test("a closer carries no info string and sits under four columns in")
    func closerRules() {
        #expect(md("```\n```js\n    ```\n```\n# after") == [
            Span("```", .keyword),
            Span("```", .keyword),
            Span("# after", .keyword)
        ])
    }

    @Test("backticks after a backtick fence make it a code span instead")
    func backtickInInfoString() {
        #expect(md("```code``` here\n# H") == [Span("```code```", .string), Span("# H", .keyword)])
    }

    @Test("a markdown fence inside a markdown fence is colored three levels down, then not")
    func nestingIsBounded() {
        // Fences of 8 down to 4 backticks, each `markdown` and each holding the next, with a
        // heading at every level. The text inside the third is still read; the fourth is not.
        var lines: [String] = []
        for level in 0..<5 {
            lines += [String(repeating: "`", count: 8 - level) + "markdown", "# h\(level)"]
        }
        for level in (0..<5).reversed() { lines.append(String(repeating: "`", count: 8 - level)) }
        let headings = md(lines.joined(separator: "\n")).filter { $0.text.hasPrefix("# h") }
        #expect(headings.map(\.text) == ["# h0", "# h1", "# h2"])
    }
}
