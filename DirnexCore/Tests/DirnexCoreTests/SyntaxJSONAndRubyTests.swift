import Foundation
import Testing

@testable import DirnexCore

/// The two grammar rows M39 ▸ Slice 9 gave a field of their own: a JSON key told from a value by
/// the colon after it, and Ruby's `=begin` … `=end`, a block comment written as whole lines.
@Suite("SyntaxHighlighter: JSON keys and Ruby's =begin")
struct SyntaxJSONAndRubyTests {
    private typealias Span = SyntaxSpan

    private func spans(_ text: String, _ language: SyntaxLanguage) -> [Span] {
        syntaxSpans(text, language)
    }

    // MARK: - JSON keys

    @Test("a key is a string with a colon after it, across spaces and a line break")
    func keysBeforeAColon() {
        let source = """
        {
          "name" : "dirnex",
          "tags": ["a", "b"],
          "nested": {"deep"
            : 1}
        }
        """
        #expect(spans(source, .json) == [
            Span("\"name\"", .typeOrTag),
            Span("\"dirnex\"", .string),
            Span("\"tags\"", .typeOrTag),
            // An array's strings are values: a comma or a bracket follows each.
            Span("\"a\"", .string),
            Span("\"b\"", .string),
            Span("\"nested\"", .typeOrTag),
            Span("\"deep\"", .typeOrTag),
            Span("1", .number)
        ])
    }

    @Test("an escaped quote stays inside the key, and an unclosed string is never one")
    func keyEdges() {
        #expect(spans(#"{"a\"b": "c"}"#, .json) == [
            Span(#""a\"b""#, .typeOrTag),
            Span("\"c\"", .string)
        ])
        // The literal stops at the line break, so the colon below belongs to nothing.
        #expect(spans("\"open\n: 1", .json) == [Span("\"open", .string), Span("1", .number)])
    }

    @Test("JSON5's unquoted names are keys too, true among them, and a value word is not")
    func unquotedKeys() {
        #expect(spans("{name: 'x', true: 1, flag: true}", .json) == [
            Span("name", .typeOrTag),
            Span("true", .typeOrTag),
            Span("1", .number),
            Span("flag", .typeOrTag),
            Span("true", .keyword)
        ])
    }

    @Test("no other grammar reads a colon after a string as a key")
    func otherLanguagesKeepTheirStrings() {
        // The reason the field is JSON's alone: a ternary's branch and a Python condition both put
        // a colon after a string that is no key.
        #expect(spans(#"x = c ? "a" : "b""#, .javascript) == [
            Span("\"a\"", .string),
            Span("\"b\"", .string)
        ])
        #expect(spans(#"if x == "a":"#, .python) == [
            Span("if", .keyword),
            Span("\"a\"", .string)
        ])
    }

    // MARK: - Ruby's =begin

    @Test("=begin … =end is one comment, the closing line's rest included")
    func embeddedDocument() {
        let source = """
        x = 1
        =begin notes
        def not_code; end
        =end trailing words
        y = nil
        """
        #expect(spans(source, .ruby) == [
            Span("1", .number),
            Span("=begin notes\ndef not_code; end\n=end trailing words", .comment),
            Span("nil", .keyword)
        ])
    }

    @Test("each delimiter counts only at the start of its line, with whitespace after it")
    func delimitersNeedColumnZero() {
        // Ruby's own answers, from `ruby` itself: an indented `=begin` and `=beginning` are syntax
        // errors rather than comments, and an indented `=end` or an `=endx` closes nothing.
        #expect(spans("  =begin\nend", .ruby) == [Span("begin", .keyword), Span("end", .keyword)])
        #expect(spans("=beginning\nend", .ruby) == [Span("end", .keyword)])
        #expect(spans("=begin\n  =end\n=endx\n=end\nend", .ruby) == [
            Span("=begin\n  =end\n=endx\n=end", .comment),
            Span("end", .keyword)
        ])
        #expect(spans("=begin\tx\n=end", .ruby) == [Span("=begin\tx\n=end", .comment)])
    }

    @Test("an unclosed =begin runs to the end of the file, and CRLF lines close it")
    func unclosedAndWindows() {
        #expect(spans("p 1\n=begin\np 2\n", .ruby) == [
            Span("1", .number),
            Span("=begin\np 2\n", .comment)
        ])
        #expect(spans("=begin\r\nx\r\n=end\r\nnil", .ruby) == [
            Span("=begin\r\nx\r\n=end", .comment),
            Span("nil", .keyword)
        ])
    }

    @Test("a grammar without the field leaves =begin as code")
    func otherLanguagesIgnoreIt() {
        #expect(spans("=begin\nTrue\n=end", .python) == [Span("True", .keyword)])
    }
}
