import Foundation
import Testing

@testable import DirnexCore

/// GFM footnotes (PLAN.md §M39 ▸ Slice 6).
///
/// GFM's spec does not cover footnotes, so each rule here is what GitHub's own renderer gave for the
/// same text (its `/markdown` API, 2026-11-13), with GitHub's `user-content-` prefix and `data-`
/// attributes left off: they belong to the script GitHub runs on its page.
@Suite("Markdown footnotes")
struct MarkdownFootnoteTests {
    private func html(_ text: String) -> String {
        MarkdownDocument.render(text).html
    }

    @Test("references are numbered by first use, and each one has a way back")
    func numbering() {
        let source = """
        Here is a reference[^1], another[^note], and a repeat[^1].

        [^1]: The first footnote.
        [^note]: A named footnote.
        """
        #expect(html(source) == """
        <p>Here is a reference<sup><a href="#fn-1" id="fnref-1" class="footnote-ref">1</a></sup>, \
        another<sup><a href="#fn-note" id="fnref-note" class="footnote-ref">2</a></sup>, and a \
        repeat<sup><a href="#fn-1" id="fnref-1-2" class="footnote-ref">1</a></sup>.</p>
        <section class="footnotes">
        <ol>
        <li id="fn-1">
        <p>The first footnote. <a href="#fnref-1" class="footnote-backref">↩</a> \
        <a href="#fnref-1-2" class="footnote-backref">↩<sup>2</sup></a></p>
        </li>
        <li id="fn-note">
        <p>A named footnote. <a href="#fnref-note" class="footnote-backref">↩</a></p>
        </li>
        </ol>
        </section>
        """)
    }

    @Test("a reference with no definition is text, and a definition nobody references is not drawn")
    func unmatched() {
        let rendered = html("A missing one[^missing].\n\n[^unused]: Never referenced.")
        #expect(rendered == "<p>A missing one[^missing].</p>")
        #expect(!rendered.contains("footnotes"))
    }

    @Test("the order is by first reference, wherever the definitions are written")
    func order() {
        let rendered = html("[^b]: Bee.\n[^a]: Ay.\n\nFirst[^a] then[^b].")
        #expect(
            rendered.contains(
                "First<sup><a href=\"#fn-a\" id=\"fnref-a\" class=\"footnote-ref\">1</a>"
            )
        )
        let first = rendered.range(of: "<li id=\"fn-a\">")
        let second = rendered.range(of: "<li id=\"fn-b\">")
        #expect(first != nil && second != nil && first!.lowerBound < second!.lowerBound)
    }

    @Test("a label matches in any case, and the anchor keeps the definition's")
    func labels() {
        let rendered = html("F[^Mixed] G[^mixed]\n\n[^Mixed]: Mixed case definition.")
        #expect(
            rendered.contains(
                "<a href=\"#fn-Mixed\" id=\"fnref-Mixed\" class=\"footnote-ref\">1</a>"
            )
        )
        #expect(
            rendered.contains(
                "<a href=\"#fn-Mixed\" id=\"fnref-Mixed-2\" class=\"footnote-ref\">1</a>"
            )
        )
        #expect(rendered.contains("<li id=\"fn-Mixed\">"))
    }

    @Test("an anchor percent-encodes its label, as GitHub's does")
    func anchors() {
        let rendered = html(
            "B[^é] C[^a\"b] O[^a*b*] N[^-dash_]\n\n[^é]: x\n[^a\"b]: y\n[^a*b*]: z\n[^-dash_]: w"
        )
        #expect(rendered.contains("href=\"#fn-%C3%A9\" id=\"fnref-%C3%A9\""))
        #expect(rendered.contains("href=\"#fn-a%22b\" id=\"fnref-a%22b\""))
        #expect(rendered.contains("href=\"#fn-a*b*\""))
        #expect(rendered.contains("href=\"#fn--dash_\""))
        #expect(rendered.contains("<li id=\"fn-%C3%A9\">"))
    }

    @Test("a label holds no whitespace, and an empty one is no label")
    func invalidLabels() {
        let source = "A[^a b] D[^] E[^ x]\n\n[^a b]: Space in label."
        #expect(html(source) == "<p>A[^a b] D[^] E[^ x]</p>\n<p>[^a b]: Space in label.</p>")
    }

    @Test(
        "a definition's first paragraph continues lazily; after a blank line, only at four columns"
    )
    func continuation() {
        let source = """
        I[^lazy] J[^two] K[^four]

        [^lazy]: First line
        lazy continuation line.
        [^two]: First paragraph.
          Two-space indented line.

          Two-space indented paragraph after blank.
        [^four]: Named.

            Indented second paragraph.
        """
        let scan = MarkdownBlockParser.scan(source)
        #expect(
            scan.footnotes["lazy"]?.blocks == [.paragraph("First line\nlazy continuation line.")]
        )
        #expect(scan.footnotes["two"]?.blocks
            == [.paragraph("First paragraph.\nTwo-space indented line.")])
        #expect(scan.footnotes["four"]?.blocks
            == [.paragraph("Named."), .paragraph("Indented second paragraph.")])
        // The two-space paragraph after the blank line is the page's own.
        #expect(html(source).contains("<p>Two-space indented paragraph after blank.</p>\n<section"))
        // The way back goes in the last paragraph.
        #expect(html(source).contains("<p>Indented second paragraph. <a href=\"#fnref-four\""))
    }

    @Test("an empty definition is still a footnote, drawn as its way back")
    func empty() {
        #expect(html("K[^empty]\n\n[^empty]:").contains("""
        <li id="fn-empty">
        <a href="#fnref-empty" class="footnote-backref">↩</a>
        </li>
        """))
    }

    @Test("a footnote whose text ends in a list draws its way back after the list")
    func endsInList() {
        let rendered = html("X[^l]\n\n[^l]: Intro.\n\n    - a\n    - b")
        #expect(rendered.contains("""
        <ul>
        <li>a</li>
        <li>b</li>
        </ul>
        <a href="#fnref-l" class="footnote-backref">↩</a>
        </li>
        """))
    }

    @Test("a definition interrupts a paragraph, and may sit inside a quote or a list item")
    func placement() {
        let source = """
        L[^quoted] item ref[^item] dup[^two]

        > [^quoted]: Defined inside a quote.

        Paragraph text
        [^two]: First definition.

        - item

          [^item]: Defined inside a list item.

        [^two]: Second definition.
        """
        let scan = MarkdownBlockParser.scan(source)
        #expect(scan.footnotes["quoted"]?.blocks == [.paragraph("Defined inside a quote.")])
        #expect(scan.footnotes["item"]?.blocks == [.paragraph("Defined inside a list item.")])
        // First definition wins, and it ended the paragraph above it.
        #expect(scan.footnotes["two"]?.blocks == [.paragraph("First definition.")])
        let rendered = html(source)
        #expect(rendered.contains("<p>Paragraph text</p>"))
        #expect(rendered.contains("<blockquote></blockquote>"))
        #expect(!rendered.contains("Second definition."))
    }

    @Test("`[^x]: url` is a footnote rather than a link definition")
    func notLinkDefinition() {
        let scan = MarkdownBlockParser.scan("Ref[^link].\n\n[^link]: https://example.com/only-url")
        #expect(scan.references.isEmpty)
        #expect(scan.footnotes["link"]?.blocks == [.paragraph("https://example.com/only-url")])
    }

    @Test(
        "references in a heading and a table cell; code, an escape and `[x][^1]` as GitHub has them"
    )
    func contexts() {
        let source = """
        ## Heading[^h]

        | a | b |
        |---|---|
        | cell[^t] | x |

        `[^h]` in code, \\[^h] escaped, and a lookalike [x][^t].

        [^h]: From a heading.
        [^t]: From a table.
        """
        let rendered = html(source)
        #expect(rendered.contains("""
        <h2 id="heading">Heading<sup><a href="#fn-h" id="fnref-h" class="footnote-ref">1</a></sup></h2>
        """))
        #expect(rendered.contains("""
        <td>cell<sup><a href="#fn-t" id="fnref-t" class="footnote-ref">2</a></sup></td>
        """))
        #expect(rendered.contains("""
        <code>[^h]</code> in code, [^h] escaped, and a lookalike [x]<sup><a href="#fn-t" id="fnref-t-2"
        """))
    }

    @Test("a footnote referenced only from another footnote is drawn after it")
    func nested() {
        let rendered = html("A[^outer]\n\n[^outer]: Outer, see[^inner].\n[^inner]: Inner.")
        #expect(rendered.contains("<li id=\"fn-outer\">"))
        #expect(rendered.contains("<li id=\"fn-inner\">\n<p>Inner. <a href=\"#fnref-inner\""))
        #expect(
            rendered.contains(
                "see<sup><a href=\"#fn-inner\" id=\"fnref-inner\" class=\"footnote-ref\">2</a>"
            )
        )
    }

    @Test(
        "a heading inside a footnote takes no anchor, and leaves the page's anchors where they were"
    )
    func headingInFootnote() {
        let source = "# One[^n]\n\n[^n]: Note.\n\n    ## Inside\n\n# Two"
        let scan = MarkdownBlockParser.scan(source)
        #expect(scan.headings.map(\.slug) == ["one", "two"])
        let rendered = html(source)
        #expect(rendered.contains("<h1 id=\"two\">Two</h1>"))
        #expect(rendered.contains("<h2>Inside</h2>"))
    }

    @Test("a document with no footnotes renders exactly as before")
    func noFootnotes() {
        #expect(html("Text [^x] here.\n\n[label]: https://example.com") == "<p>Text [^x] here.</p>")
    }
}
