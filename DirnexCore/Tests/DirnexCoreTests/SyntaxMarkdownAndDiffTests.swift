import Foundation
import Testing

@testable import DirnexCore

/// The two line-oriented scanners (PLAN.md §M17 ▸ Slice 2). Together because they share a shape:
/// every decision is made from the first characters of a line, and the whole risk is that two
/// constructs open with the same character and are tested in the wrong order.
@Suite("SyntaxMarkdown and SyntaxDiff")
struct SyntaxMarkdownAndDiffTests {
    private typealias Span = SyntaxSpan

    private func md(_ text: String) -> [Span] { syntaxSpans(text, .markdown) }
    private func diff(_ text: String) -> [Span] { syntaxSpans(text, .diff) }

    // MARK: - Markdown blocks

    @Test("a heading takes the whole line, and needs a space after its hashes")
    func headings() {
        #expect(md("# Title\n### Third\n") == [
            Span("# Title", .keyword),
            Span("### Third", .keyword)
        ])
        // `#hashtag` and a seventh hash are not headings.
        #expect(md("#hashtag\n####### too many\n").isEmpty)
    }

    @Test("a thematic break is tested before the list marker it starts like")
    func thematicBreakBeatsListMarker() {
        // Written the other way round, `---` reads as a bullet with no content.
        #expect(md("---") == [Span("---", .keyword)])
        #expect(md("- item") == [Span("-", .number)])
    }

    @Test("list markers colour, ordered and unordered, and the space after them does not")
    func listMarkers() {
        #expect(md("- a\n* b\n+ c\n1. d\n2) e\n") == [
            Span("-", .number),
            Span("*", .number),
            Span("+", .number),
            Span("1.", .number),
            Span("2)", .number)
        ])
        // No space after the marker: ordinary text, not a list.
        #expect(md("-notalist\n1.notalist").isEmpty)
    }

    @Test("a blockquote is an aside, and takes the comment colour")
    func blockquote() {
        #expect(md("> quoted") == [Span("> quoted", .comment)])
    }

    @Test("a fenced block runs to its matching closer, and only its own character closes it")
    func fences() {
        #expect(md("```swift\nlet x = 1\n```\n# after") == [
            Span("```swift", .keyword),
            Span("let", .keyword),
            Span("1", .number),
            Span("```", .keyword),
            Span("# after", .keyword)
        ])
        // A ``` block may contain ~~~, and vice versa. Neither names a language, so the body of
        // each is left in the document's own colour.
        #expect(md("~~~\n```\n~~~") == [Span("~~~", .keyword), Span("~~~", .keyword)])
    }

    @Test("a fence names its own language, and an undecorated one colours nothing inside")
    func fenceBodyTakesItsInfoStringsLanguage() {
        // The whole point of the change: a tree diagram or a plain transcript is the largest thing
        // on a README's page, and painting it one colour makes the loudest region the least
        // meaningful one.
        #expect(md("```\nDirnex/\n├── PLAN.md\n```") == [
            Span("```", .keyword),
            Span("```", .keyword)
        ])
        // The spelled-out spellings route too, not just the ones that happen to be extensions.
        #expect(md("```shell\n# note\n```") == [
            Span("```shell", .keyword),
            Span("# note", .comment),
            Span("```", .keyword)
        ])
        // An info string nothing claims is the undecorated case again, not an error.
        #expect(md("```brainfuck\n+++.\n```") == [
            Span("```brainfuck", .keyword),
            Span("```", .keyword)
        ])
        // Only the first word is the language; the rest belongs to whatever renders the document.
        #expect(md("```json title=\"a.json\"\n\"k\"\n```") == [
            Span("```json title=\"a.json\"", .keyword),
            Span("\"k\"", .string),
            Span("```", .keyword)
        ])
    }

    @Test("a fence inside a fence terminates, and is bounded at two levels by construction")
    func nestedFences() {
        // A fence closes on the first run of its *own* character, so a ~~~ body can hold ``` blocks
        // and those can hold neither — there is no third level for the re-entrant scan to reach.
        #expect(md("~~~markdown\n```swift\nlet x = 1\n```\n~~~") == [
            Span("~~~markdown", .keyword),
            Span("```swift", .keyword),
            Span("let", .keyword),
            Span("1", .number),
            Span("```", .keyword),
            Span("~~~", .keyword)
        ])
    }

    @Test("an unclosed fence runs to the end of the buffer")
    func unterminatedFence() {
        #expect(md("```\nstill inside\n") == [Span("```", .keyword)])
        // …and its body is still scanned, which is what a file truncated at the preview's byte
        // limit hands over.
        #expect(md("```swift\nlet x = 1\n") == [
            Span("```swift", .keyword),
            Span("let", .keyword),
            Span("1", .number)
        ])
        // A fence that is the file's last line has no body at all.
        #expect(md("text\n```swift") == [Span("```swift", .keyword)])
    }

    // MARK: - Markdown inline

    @Test("a code span closes on a run of the same length")
    func codeSpans() {
        #expect(md("use `code` here") == [Span("`code`", .string)])
        #expect(md("``a `b` c`` end") == [Span("``a `b` c``", .string)])
        // No closer on the line: nothing is painted.
        #expect(md("a ` dangling").isEmpty)
    }

    @Test("emphasis needs both flanks, which is what leaves arithmetic alone")
    func emphasis() {
        #expect(md("*one* and **two** and _three_") == [
            Span("*one*", .typeOrTag),
            Span("**two**", .typeOrTag),
            Span("_three_", .typeOrTag)
        ])
        // A delimiter followed by a space opens nothing, so `2 * 3 * 4` stays arithmetic.
        #expect(md("2 * 3 * 4").isEmpty)
    }

    @Test("an intraword underscore is not emphasis")
    func intrawordUnderscore() {
        // CommonMark's rule, and the same asymmetry NOTES.md ▸ Localization measured from the
        // other side: `*` pairs anywhere, `_` does not pair inside a word.
        #expect(md("report_2026_final.pdf and a_b_c").isEmpty)
    }

    @Test("a link gives its text and its URL two kinds")
    func links() {
        #expect(md("see [the plan](PLAN.md) now") == [
            Span("[the plan]", .typeOrTag),
            Span("(PLAN.md)", .string)
        ])
        // A reference link's bracket group stands on its own.
        #expect(md("[label] alone") == [Span("[label]", .typeOrTag)])
        #expect(md("[unclosed here").isEmpty)
    }

    @Test("Markdown line handling survives CRLF")
    func markdownWindowsLineEndings() {
        #expect(md("# Title\r\n- item\r\n") == [
            Span("# Title", .keyword),
            Span("-", .number)
        ])
    }

    @Test("an empty document yields no tokens")
    func emptyMarkdown() {
        #expect(SyntaxHighlighter.tokens(in: "", language: .markdown).isEmpty)
        #expect(md("\n\n   \n").isEmpty)
    }

    // MARK: - Diff

    @Test("the file headers are tested before the +/- lines that start the same way")
    func headersBeatChangeLines() {
        // The whole correctness argument for this scanner: `--- a/x` opens like a deletion, and a
        // diff whose own header reads as a deletion is wrong exactly where a reader orients.
        #expect(diff("--- a/x.swift\n+++ b/x.swift\n") == [
            Span("--- a/x.swift", .typeOrTag),
            Span("+++ b/x.swift", .typeOrTag)
        ])
    }

    @Test("a hunk header, an added line, a removed line and a context line")
    func changeLines() {
        let source = "@@ -1,3 +1,4 @@ func f() {\n context\n+added\n-removed\n\\ No newline\n"
        #expect(diff(source) == [
            Span("@@ -1,3 +1,4 @@ func f() {", .keyword),
            Span("+added", .inserted),
            Span("-removed", .deleted),
            Span("\\ No newline", .comment)
        ])
    }

    @Test("git's extended headers colour rather than sitting plain between hunks")
    func gitExtendedHeaders() {
        let source = """
        diff --git a/x b/x
        new file mode 100644
        index 0000000..e69de29
        similarity index 95%
        rename from old
        rename to new
        """
        #expect(diff(source).allSatisfy { $0.kind == .typeOrTag })
        #expect(diff(source).count == 6)
    }

    @Test("an empty patch yields no tokens")
    func emptyDiff() {
        #expect(SyntaxHighlighter.tokens(in: "", language: .diff).isEmpty)
        #expect(diff("\n\n").isEmpty)
    }
}
