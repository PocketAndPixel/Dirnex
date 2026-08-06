import Foundation
import Testing

@testable import DirnexCore

/// The XML/HTML/SVG/plist scanner (PLAN.md §M17 ▸ Slice 2), which M16 makes load-bearing: an
/// `.html` now previews as its source by default, so this is what stops it being one colour.
@Suite("SyntaxMarkupScanner")
struct SyntaxMarkupScannerTests {
    private typealias Span = SyntaxSpan

    private func spans(_ text: String) -> [Span] { syntaxSpans(text, .markup) }

    // MARK: - Elements

    @Test("an element gives its brackets and name, its attribute names and its values")
    func element() {
        #expect(spans("<p class=\"lead\">hi</p>") == [
            Span("<p", .typeOrTag),
            Span("class", .keyword),
            Span("\"lead\"", .string),
            Span(">", .typeOrTag),
            Span("</p", .typeOrTag),
            Span(">", .typeOrTag)
        ])
    }

    @Test("HTML's unquoted value and bare attribute both land right")
    func htmlAttributeForms() {
        // The one `Bool` in the scanner: `42` is a value because of the `=` before it, and there
        // is nothing else that tells it from an attribute name.
        #expect(spans("<div data-id=42 hidden />") == [
            Span("<div", .typeOrTag),
            Span("data-id", .keyword),
            Span("42", .string),
            Span("hidden", .keyword),
            Span("/>", .typeOrTag)
        ])
    }

    @Test("a namespaced name keeps its colon")
    func namespacedNames() {
        #expect(spans("<xsi:type xml:lang='en'>").first == Span("<xsi:type", .typeOrTag))
    }

    @Test("a `<` with no name after it is not an element")
    func lessThanInProse() {
        // The case that decides whether a stray comparison paints the rest of the document.
        #expect(spans("a < b and 1 <2").isEmpty)
    }

    // MARK: - The bracketed forms

    @Test("comment, CDATA, doctype and processing instruction each take their own kind")
    func bracketedForms() {
        #expect(spans("<!-- note -->") == [Span("<!-- note -->", .comment)])
        #expect(spans("<![CDATA[ raw <x> ]]>") == [Span("<![CDATA[ raw <x> ]]>", .string)])
        #expect(spans("<!DOCTYPE html>") == [Span("<!DOCTYPE html>", .keyword)])
        #expect(spans("<?xml version=\"1.0\"?>") == [Span("<?xml version=\"1.0\"?>", .keyword)])
    }

    @Test("a comment claims its opening before the doctype form can")
    func longestBracketedFormWins() {
        // `<!--` and `<!` both match at the same position; tested in the wrong order, every
        // comment would end at its first `>`.
        #expect(spans("<!-- a > b -->") == [Span("<!-- a > b -->", .comment)])
    }

    @Test("an unclosed comment runs to the end of the buffer")
    func unterminatedComment() {
        // What a file truncated at `TextPreview.byteLimit` hands over.
        #expect(spans("<p><!-- and then") == [
            Span("<p", .typeOrTag),
            Span(">", .typeOrTag),
            Span("<!-- and then", .comment)
        ])
    }

    @Test("an unclosed attribute value stops at the tag's own bracket")
    func unterminatedValue() {
        // A missing quote costs its tag, never the document.
        #expect(spans("<a href=\"oops>text") == [
            Span("<a", .typeOrTag),
            Span("href", .keyword),
            Span("\"oops", .string),
            Span(">", .typeOrTag)
        ])
    }

    @Test("a value may wrap across lines, because hand-written markup does")
    func multiLineValue() {
        #expect(spans("<p title=\"one\ntwo\">")[2] == Span("\"one\ntwo\"", .string))
    }

    // MARK: - Entities

    @Test("named, decimal and hex entities colour; a bare ampersand does not")
    func entities() {
        #expect(spans("a &amp; b &#160; c &#x1F600; d") == [
            Span("&amp;", .number),
            Span("&#160;", .number),
            Span("&#x1F600;", .number)
        ])
        // Invalid markup and extremely common in real pages, so silence is the right answer.
        #expect(spans("Tom & Jerry").isEmpty)
        #expect(spans("&notanentityatall;").isEmpty)
    }

    // MARK: - Real shapes

    @Test("an Info.plist tokenizes as the XML it is")
    func propertyList() {
        let source = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>Dirnex</string>
        </dict>
        </plist>
        """
        let spans = spans(source)
        #expect(spans.first == Span("<?xml version=\"1.0\" encoding=\"UTF-8\"?>", .keyword))
        #expect(spans.contains(Span("<key", .typeOrTag)))
        #expect(spans.contains(Span("\"1.0\"", .string)))
        #expect(spans.allSatisfy { $0.kind != .plain })
    }

    @Test("an empty document yields no tokens")
    func emptyDocument() {
        #expect(SyntaxHighlighter.tokens(in: "", language: .markup).isEmpty)
    }
}
