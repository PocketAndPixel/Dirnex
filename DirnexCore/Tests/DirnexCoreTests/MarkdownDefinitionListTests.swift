import Foundation
import Testing

@testable import DirnexCore

/// Definition lists (PLAN.md §M39 ▸ Slice 7).
///
/// GitHub draws none, and no `.md` on this Mac writes one, so the rules are Pandoc's as its manual
/// states them. What the corpus does hold is the shape as *prose*: a wrapped line of HISTORY.md
/// that opens with `: "conflicts"`, pinned below as a paragraph.
@Suite("Markdown definition lists")
struct MarkdownDefinitionListTests {
    private func html(_ text: String) -> String {
        MarkdownDocument.render(text).html
    }

    @Test("a term over its definitions, drawn bare with no blank line between")
    func tight() {
        #expect(html("Apple\n: A fruit that keeps.\n: A company.") == """
        <dl>
        <dt>Apple</dt>
        <dd>A fruit that keeps.</dd>
        <dd>A company.</dd>
        </dl>
        """)
    }

    @Test("a blank line before a definition draws it as a paragraph, decided per definition")
    func loose() {
        #expect(html("Apple\n\n: A fruit.\n: A company.") == """
        <dl>
        <dt>Apple</dt>
        <dd><p>A fruit.</p></dd>
        <dd>A company.</dd>
        </dl>
        """)
    }

    @Test("groups follow each other into one list, with or without a blank line between")
    func groups() {
        let expected = """
        <dl>
        <dt>Apple</dt>
        <dd>Pomaceous.</dd>
        <dt><em>Orange</em></dt>
        <dd>Citrus.</dd>
        </dl>
        """
        #expect(html("Apple\n: Pomaceous.\n\n*Orange*\n: Citrus.") == expected)
        // A line with a definition under it is the next term, not more of this definition.
        #expect(html("Apple\n: Pomaceous.\n*Orange*\n: Citrus.") == expected)
    }

    @Test("a definition continues lazily, and takes blocks indented four columns")
    func continuation() {
        let source = """
        Term
        :   First line
        continued here.

            Second paragraph.

            - one
            - two

        After the list.
        """
        #expect(html(source) == """
        <dl>
        <dt>Term</dt>
        <dd>First line
        continued here.
        <p>Second paragraph.</p>
        <ul>
        <li>one</li>
        <li>two</li>
        </ul></dd>
        </dl>
        <p>After the list.</p>
        """)
    }

    /// A paragraph's *second* line opening with `: ` is the syntax itself, and reads as a definition,
    /// as it does in Pandoc. HISTORY.md's line is the third of its paragraph.
    @Test("a `:` line further into a paragraph is prose, as HISTORY.md wraps one")
    func prose() {
        let wrapped = """
        - `Rename` reused. Three recurring traps, fixed at the source: **hand-rolled plurals** became
          plurals through `String(localized:)` interpolation — the conflict count (`count == 1 ? "conflict"
          : "conflicts"` → `%lld name conflicts`) and the confirm button (`renaming == 1 ? "Item" : "Items"`
        """
        #expect(!html(wrapped).contains("<dl>"))
        #expect(html("One line\nanother line\n: not a definition") == """
        <p>One line
        another line
        : not a definition</p>
        """)
        #expect(html(": alone, with no term") == "<p>: alone, with no term</p>")
    }

    @Test("only a line that would open a paragraph is a term, and only `: ` is a marker")
    func notTerms() {
        #expect(!html("# Heading\n: x").contains("<dl>"))
        #expect(!html("- item\n\n: x").contains("<dl>"))
        #expect(!html("> quoted\n\n: x").contains("<dl>"))
        #expect(!html("| a |\n| - |\n: x").contains("<dl>"))
        // An emoji shortcode opening a line is no marker.
        #expect(!html("Term\n:smile: hello").contains("<dl>"))
        // Two blank lines are more than a term may have under it.
        #expect(!html("Term\n\n\n: x").contains("<dl>"))
        // Four columns in is code.
        #expect(!html("Term\n    : x").contains("<dl>"))
        #expect(html("Term\n   : x").contains("<dd>x</dd>"))
        #expect(html("Term\n:\tx").contains("<dd>x</dd>"))
    }

    @Test("a heading or footnote inside a definition is found like any other")
    func nested() {
        let source = """
        Term
        : Text[^n]

            ## Inside

        [^n]: The note.
        """
        let rendered = html(source)
        #expect(rendered.contains("<h2 id=\"inside\">Inside</h2>"))
        #expect(rendered.contains("<li id=\"fn-n\">"))
    }

    @Test("a definition list inside a list item and a quote, a lazy `:` line included")
    func inContainers() {
        let inItem = "<li><dl>\n<dt>Term</dt>\n<dd>Def</dd>\n</dl></li>"
        #expect(html("- Term\n  : Def").contains(inItem))
        #expect(html("- Term\n: Def").contains(inItem))
        #expect(html("> Term\n> : Def").contains("<blockquote><dl>"))
        #expect(html("> Term\n: Def").contains("<blockquote><dl>"))
    }
}
