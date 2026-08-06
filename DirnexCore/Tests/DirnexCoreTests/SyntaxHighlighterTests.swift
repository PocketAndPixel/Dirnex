import Foundation
import Testing

@testable import DirnexCore

/// The single-pass scanner (PLAN.md §M17 ▸ Slice 1).
///
/// Every case here is asserted as *text plus kind* rather than as offsets, because an offset
/// assertion is unreadable and would pass for the wrong reason the moment a fixture gains a
/// character. The one exception is `offsetsIndexAnNSString`, where the offset **is** the claim.
@Suite("SyntaxHighlighter")
struct SyntaxHighlighterTests {
    private typealias Span = SyntaxSpan

    private func spans(_ text: String, _ language: SyntaxLanguage) -> [Span] {
        syntaxSpans(text, language)
    }

    // MARK: - Every kind, in one file of each family

    @Test("a Swift file tokenizes as keyword, type, string, number and comment")
    func swiftFile() {
        let source = """
        // Header
        import Foundation
        @MainActor final class Box {
            let name: String = "hi"
            var count = 0xFF
        }
        """
        #expect(spans(source, .swift) == [
            Span("// Header", .comment),
            Span("import", .keyword),
            Span("@MainActor", .keyword),
            Span("final", .keyword),
            Span("class", .keyword),
            Span("let", .keyword),
            Span("String", .typeOrTag),
            Span("\"hi\"", .string),
            Span("var", .keyword),
            Span("0xFF", .number)
        ])
    }

    @Test("a Makefile tokenizes on the hash-comment grammar")
    func makefile() {
        let source = """
        # Build rules
        ifeq ($(DEBUG),1)
            CFLAGS += -g
        endif
        """
        #expect(spans(source, .makefile) == [
            Span("# Build rules", .comment),
            Span("ifeq", .keyword),
            Span("1", .number),
            Span("endif", .keyword)
        ])
    }

    @Test("JSON colours its three literals and nothing else")
    func json() {
        let source = #"{"on": true, "off": false, "gone": null, "n": -1.5e3}"#
        #expect(spans(source, .json) == [
            Span("\"on\"", .string),
            Span("true", .keyword),
            Span("\"off\"", .string),
            Span("false", .keyword),
            Span("\"gone\"", .string),
            Span("null", .keyword),
            Span("\"n\"", .string),
            // The sign is not part of the literal: a number starts at a digit, because deciding
            // whether a leading `-` is a sign or an operator needs the token before it.
            Span("1.5e3", .number)
        ])
    }

    @Test("SQL folds case for both word sets, and takes '' as an escaped quote by accident")
    func sql() {
        let source = "select Name from Orders where note like 'O''Brien' -- who?\ncreate TABLE t (id BIGINT);"
        #expect(spans(source, .sql) == [
            Span("select", .keyword),
            Span("from", .keyword),
            Span("where", .keyword),
            Span("like", .keyword),
            // SQL escapes a quote by doubling it, so the literal comes back as two adjacent string
            // tokens rather than one. They abut exactly, so the rendering is identical — asserted
            // here so a future "fix" knows it was measured rather than missed.
            Span("'O'", .string),
            Span("'Brien'", .string),
            Span("-- who?", .comment),
            Span("create", .keyword),
            Span("TABLE", .keyword),
            Span("BIGINT", .typeOrTag)
        ])
    }

    // MARK: - Running off the end

    @Test("a block comment with no closer runs to the end of the buffer")
    func unterminatedBlockComment() {
        #expect(spans("let x = 1\n/* and then", .swift) == [
            Span("let", .keyword),
            Span("1", .number),
            Span("/* and then", .comment)
        ])
    }

    @Test("a string with no closer stops at the line break, not at the end of the file")
    func unterminatedString() {
        // The whole point of `StringLiteral.spansLines` being false for ordinary quotes: one
        // stray quote costs its own line, never the rest of the document.
        #expect(spans("let a = \"oops\nlet b = 2", .swift) == [
            Span("let", .keyword),
            Span("\"oops", .string),
            Span("let", .keyword),
            Span("2", .number)
        ])
    }

    @Test("a multi-line string with no closer does run to the end")
    func unterminatedMultilineString() {
        #expect(spans("let a = \"\"\"\nstill inside\n", .swift) == [
            Span("let", .keyword),
            Span("\"\"\"\nstill inside\n", .string)
        ])
    }

    @Test("a buffer truncated mid-token yields a token that ends with the buffer")
    func truncatedBuffer() throws {
        // What `TextPreview` hands over at `byteLimit`: a file cut wherever the limit fell.
        let whole = "let s = \"a long string that keeps going\""
        let cut = String(whole.prefix(20))
        let tokens = SyntaxHighlighter.tokens(in: cut, language: .swift)
        let last = try #require(tokens.last)
        #expect(last.kind == .string)
        #expect(last.end == cut.utf16.count)
    }

    @Test("an escape as the buffer's last unit does not run past the end")
    func escapeAtEndOfBuffer() {
        // `index += 2` over the final unit is the one place the scan can step past the buffer.
        #expect(spans("\"ab\\", .swift) == [Span("\"ab\\", .string)])
    }

    @Test("an empty file yields no tokens")
    func emptyFile() {
        #expect(SyntaxHighlighter.tokens(in: "", language: .swift).isEmpty)
        #expect(spans("\n\n  \n", .swift).isEmpty)
    }

    // MARK: - Line breaks

    @Test("CRLF ends a line comment, and the next line still scans")
    func windowsLineEndings() {
        // docs/NOTES.md: a Swift `Character` makes CRLF one grapheme equal to neither "\r" nor
        // "\n", so a `Character`-based scan finds no line break here at all and swallows the file.
        // Scanning UTF-16 code units is what makes this ordinary.
        #expect(spans("// note\r\nlet x = 1\r\n", .swift) == [
            Span("// note", .comment),
            Span("let", .keyword),
            Span("1", .number)
        ])
    }

    @Test("a lone CR ends a line comment too")
    func classicMacLineEndings() {
        #expect(spans("# note\rtrue\r", .yaml) == [
            Span("# note", .comment),
            Span("true", .keyword)
        ])
    }

    // MARK: - The traps a single pass has to get right

    @Test("nested block comments end where the language says they do")
    func nestedBlockComments() {
        let source = "/* a /* b */ c */ let x = 1"
        // Swift nests, so the outer comment swallows the inner one and `let` is code.
        #expect(spans(source, .swift) == [
            Span("/* a /* b */ c */", .comment),
            Span("let", .keyword),
            Span("1", .number)
        ])
        // C does not, so the comment ends at the first `*/` and the tail is code.
        #expect(spans(source, .cLanguage).first == Span("/* a /* b */", .comment))
    }

    @Test("an identifier that starts with a keyword is not a keyword")
    func keywordPrefixedIdentifier() {
        #expect(spans("class_name classy class", .swift) == [Span("class", .keyword)])
    }

    @Test("a preprocessor directive colours only at the start of its line")
    func preprocessorNeedsLineStart() {
        #expect(spans("  #include <a.h>", .cLanguage) == [Span("#include", .keyword)])
        // The stringify operator inside a macro body is the case the line-start test exists for.
        #expect(spans("int x = 1; #define", .cLanguage) == [
            Span("int", .keyword),
            Span("1", .number)
        ])
    }

    @Test("an annotation sigil needs an identifier, which is what leaves @\"…\" a string")
    func annotationSigilVersusObjectiveCLiteral() {
        #expect(spans("@interface W", .objectiveC) == [Span("@interface", .keyword)])
        #expect(spans("s = @\"hi\";", .objectiveC) == [Span("\"hi\"", .string)])
    }

    @Test("a comment inside a string is a string, and a string inside a comment is a comment")
    func delimitersDoNotCrossEachOther() {
        #expect(spans("let a = \"// not a comment\"", .swift) == [
            Span("let", .keyword),
            Span("\"// not a comment\"", .string)
        ])
        #expect(spans("// let \"x\"", .swift) == [Span("// let \"x\"", .comment)])
    }

    @Test("a triple quote claims its opening before a single quote can")
    func longestStringDelimiterWins() {
        // The compiled grammar sorts openers by length. Written the other way round, a docstring's
        // body would scan as code — which is the quiet failure the sort exists to prevent.
        #expect(spans("\"\"\"\ndef class\n\"\"\"\ndef f():", .python) == [
            Span("\"\"\"\ndef class\n\"\"\"", .string),
            Span("def", .keyword)
        ])
    }

    @Test("a shell's single quotes have no escape character")
    func shellSingleQuotesTakeNoEscape() {
        // `'\'` is a complete literal in a shell: the backslash is an ordinary character inside
        // single quotes, so the second quote closes it.
        #expect(spans("echo '\\' done", .shell) == [
            Span("echo", .keyword),
            Span("'\\'", .string),
            Span("done", .keyword)
        ])
    }

    @Test("numbers cover the radices, separators, suffixes and signed exponents")
    func numberForms() {
        let kinds = spans("0xFF 0b1010 1_000_000 3.14f 1e-9 0x1p-3 10L 0", .cPlusPlus)
        #expect(kinds.allSatisfy { $0.kind == .number })
        #expect(kinds.map(\.text) == [
            "0xFF", "0b1010", "1_000_000", "3.14f", "1e-9", "0x1p-3", "10L", "0"
        ])
    }

    @Test("a member access is not a decimal point")
    func numberStopsBeforeAMember() {
        #expect(spans("let n = 1.description", .swift) == [
            Span("let", .keyword),
            Span("1", .number)
        ])
    }

    // MARK: - The contract with the app

    @Test("offsets index an NSString, which is what the app builds an NSRange from")
    func offsetsIndexAnNSString() throws {
        // A non-BMP character is two UTF-16 code units and one `Character`, so this is the fixture
        // that tells the two apart. `SyntaxToken`'s whole reason for choosing UTF-16 is that the
        // app must not re-walk the string to use what comes back.
        let source = "let a = \"😀\"\nlet b = 12"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .swift)
        let string = source as NSString
        let rendered = tokens.map { string.substring(
            with: NSRange(location: $0.offset, length: $0.length)
        ) }
        #expect(rendered == ["let", "\"😀\"", "let", "12"])
    }

    @Test("tokens come back ordered, non-overlapping, in range and never empty")
    func tokenStreamInvariants() {
        let source = """
        /* header */
        @objc final class Box: NSObject {
            let 名前 = "🎉 done \\" ok"
            #warning("x")
            var n = 1_000.5e-2  // trailing
        }
        """
        let tokens = SyntaxHighlighter.tokens(in: source, language: .swift)
        let limit = source.utf16.count
        var previousEnd = 0
        var ordered = true
        for token in tokens {
            if token.offset < previousEnd || token.length <= 0 || token.end > limit { ordered = false }
            previousEnd = token.end
        }
        #expect(ordered)
        #expect(!tokens.isEmpty)
    }

    @Test("the scanner never emits .plain")
    func plainIsNeverEmitted() {
        // `.plain` names the text view's own colour, which is already on screen — a token for it
        // would be a span that changes nothing.
        var seen = false
        for language in SyntaxLanguage.allCases {
            let source = "a 1 \"s\" // c\n#x @y 'q'\nclass if select true FROM def end"
            if SyntaxHighlighter.tokens(in: source, language: language).contains(
                where: { $0.kind == .plain }
            ) { seen = true }
        }
        #expect(!seen)
    }
}
