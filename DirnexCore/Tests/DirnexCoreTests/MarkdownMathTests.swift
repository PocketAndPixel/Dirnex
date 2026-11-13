import Foundation
import Testing

@testable import DirnexCore

/// Math's four spellings in a Markdown document (PLAN.md §M39 ▸ Slice 8).
///
/// Every case marked GitHub was read off GitHub's renderer on 2026-11-14 (`MarkdownMath`): the
/// rule for when a `$` opens and closes is written down nowhere, and the one prose depends on is
/// that a price stays a price.
@Suite("Markdown math")
struct MarkdownMathTests {
    private func html(_ text: String) -> String {
        MarkdownDocument.render(text).html
    }

    /// The inline nodes of one paragraph.
    private func nodes(_ text: String) -> [MarkdownInline] {
        MarkdownInlineParser.parse(text)
    }

    private func math(_ tex: String, display: Bool = false, written: String? = nil) -> MarkdownInline {
        .math(tex: tex, display: display, written: written ?? (display ? "$$\(tex)$$" : "$\(tex)$"))
    }

    @Test("`$x$` is inline math, drawn as MathML")
    func inline() {
        #expect(nodes("a $x^2$ b") == [.text("a "), math("x^2"), .text(" b")])
        #expect(
            html("a $x^2$ b")
                == "<p>a <math><msup><mi>x</mi><mn>2</mn></msup></math> b</p>"
        )
    }

    @Test("prices stay prices: a `$` closes only with no space before it (GitHub)")
    func prices() {
        #expect(nodes("costs $5 and $10 today") == [.text("costs $5 and $10 today")])
        #expect(nodes("$5 and $x$") == [.text("$5 and "), math("x")])
        #expect(nodes("$x $y$") == [.text("$x "), math("y")])
        #expect(nodes("a $ x$ and $x $ b") == [.text("a $ x$ and $x $ b")])
    }

    @Test(
        "a closing `$` before a letter, a digit or `_` closes nothing; before anything else it does (GitHub)"
    )
    func afterTheCloser() {
        for text in ["$x$5", "$x$y", "$x$_"] {
            #expect(nodes(text) == [.text(text)], "\(text)")
        }
        #expect(nodes("$x$é") == [math("x"), .text("é")])
        #expect(nodes("$x$.") == [math("x"), .text(".")])
        #expect(nodes("$x$’s") == [math("x"), .text("’s")])
        #expect(nodes("($x$)") == [.text("("), math("x"), .text(")")])
    }

    @Test(
        "a `$` opens after whitespace or `(` and at the start, not after a letter or other punctuation (GitHub)"
    )
    func beforeTheOpener() {
        for text in ["word$x$", "\"$x$\"", "[$x$", "-$x$", "é$x$", "\u{00A0}$x$", "“$x$”"] {
            #expect(!nodes(text).contains { if case .math = $0 { true } else { false } }, "\(text)")
        }
        #expect(nodes("a\t$x$") == [.text("a\t"), math("x")])
        #expect(nodes("a\n$x$") == [.text("a"), .softBreak, math("x")])
        #expect(nodes("`a`$x$") == [.code("a"), math("x")])
        // GitHub draws math straight after `**` and not after a single `*`.
        #expect(nodes("**$x$**") == [.strong([math("x")])])
        #expect(nodes("*$x$*") == [.emphasis([.text("$x$")])])
        // Nor straight after another formula: `$x$$y$` is one formula and text.
        #expect(nodes("$x$$y$") == [math("x"), .text("$y$")])
    }

    @Test("a template's `${name}`s are text, and a formula ending in `${` is not (GitHub)")
    func templates() {
        for text in ["charges ${a}, which is (${b}).", "a ${d}-${e} b", "a `c`${d}-${e} b"] {
            #expect(!nodes(text).contains { if case .math = $0 { true } else { false } }, "\(text)")
        }
        #expect(nodes("a ${d}-$ b") == [.text("a "), math("{d}-"), .text(" b")])
        #expect(nodes("a $x-${e} b") == [.text("a "), math("x-"), .text("{e} b")])
        #expect(nodes("a $x${y}$ b") == [.text("a "), math("x"), .text("{y}$ b")])
    }

    @Test("a dollar inside a later code span closes nothing, since GitHub reads code spans first")
    func codeSpanCloser() {
        #expect(
            nodes("use ${a} as in `\"${a}\"` here")
                == [.text("use ${a} as in "), .code("\"${a}\""), .text(" here")]
        )
        #expect(
            nodes("any $-cost, never a `$`.") == [
                .text("any $-cost, never a "),
                .code("$"),
                .text(".")
            ]
        )
        #expect(nodes("a $x `y` z$ b") == [.text("a $x "), .code("y"), .text(" z$ b")])
    }

    @Test("what is between the dollars is TeX: no emphasis, no escapes, braces kept")
    func literal() {
        #expect(nodes("$a*b$ and $c*d$") == [math("a*b"), .text(" and "), math("c*d")])
        #expect(nodes("$*x*$") == [math("*x*")])
        // GitHub reads `\{` as Markdown's escape first and draws no braces; the TeX means them.
        #expect(nodes("$X = \\{x_1\\}$") == [math("X = \\{x_1\\}")])
        #expect(nodes("$a \\\\ b$") == [math("a \\\\ b")])
        // `\$` inside is TeX's dollar, so it does not close.
        #expect(nodes("$\\$5$") == [math("\\$5")])
    }

    @Test("an escaped dollar is a dollar, and opens nothing")
    func escaped() {
        #expect(nodes("\\$x\\$") == [.text("$x$")])
        #expect(nodes("costs \\$5, or $x$") == [.text("costs $5, or "), math("x")])
    }

    @Test("`$$x$$` is display math, inline or alone, and wrapped to scroll")
    func display() {
        #expect(nodes("a $$x$$ b") == [.text("a "), math("x", display: true), .text(" b")])
        #expect(
            html("$$x$$")
                == "<p><span class=\"math-display\"><math display=\"block\"><mi>x</mi></math></span></p>"
        )
        #expect(nodes("$$ x $$") == [.text("$$ x $$")])
        #expect(nodes("a$$x$$b") == [.text("a$$x$$b")])
        #expect(nodes("$$$x$$$") == [.text("$$$x$$$")])
    }

    @Test("a display block between lines of its own, trailing spaces and all")
    func displayBlock() {
        let source = "$$\n\\sum_{i=1}^n i\n$$"
        #expect(nodes(source) == [math("\n\\sum_{i=1}^n i\n", display: true, written: source)])
        #expect(html("$$  \nx\n$$").contains("<math display=\"block\"><mi>x</mi></math>"))
        #expect(html("Text before\n$$\nx\n$$\nafter").contains("<math display=\"block\">"))
        // A single `$` does not cross into its line break.
        #expect(nodes("$\nx$") == [.text("$"), .softBreak, .text("x$")])
    }

    @Test("`` $`…`$ `` has no boundary rules and trims as a code span (GitHub)")
    func dollarBacktick() {
        #expect(
            nodes("word$`x`$word") == [.text("word"), math("x", written: "$`x`$"), .text("word")]
        )
        #expect(nodes("$` x `$") == [math("x", written: "$` x `$")])
        #expect(nodes("$``a`b``$") == [math("a`b", written: "$``a`b``$")])
        #expect(nodes("$`$x$`$") == [math("$x$", written: "$`$x$`$")])
        // A `$` before a code span that is not followed by `$` is a dollar and a code span.
        #expect(nodes("$`a`b$") == [.text("$"), .code("a"), .text("b$")])
    }

    @Test("no math in a link's text, and an image's alt keeps its dollars (GitHub)")
    func links() {
        #expect(
            html("[the $x$ link](https://example.com)")
                == "<p><a href=\"https://example.com\">the $x$ link</a></p>"
        )
        #expect(html("![a $x$](https://e.com/i.png)").contains("alt=\"a $x$\""))
    }

    @Test("a code span wins over a dollar inside it")
    func codeSpan() {
        #expect(nodes("`$x$`") == [.code("$x$")])
        #expect(nodes("$x$`$y$`") == [math("x"), .code("$y$")])
    }

    @Test("a ```math fence is display math; ```Math and a broken one stay code")
    func fence() {
        #expect(
            html("```math\n\\sqrt{2}\n```")
                == "<div class=\"math-display\"><math display=\"block\"><msqrt><mn>2</mn></msqrt></math></div>"
        )
        #expect(html("```Math\n\\sqrt{2}\n```").hasPrefix("<pre><code class=\"language-Math\">"))
        #expect(html("~~~math\nx\n~~~").contains("<math display=\"block\">"))
        #expect(
            html("```math\n\\frac{1}{2\n```")
                == "<pre><code class=\"language-math\">\\frac{1}{2\n</code></pre>"
        )
    }

    @Test("a formula whose TeX does not close draws as the text it was written as")
    func broken() {
        #expect(html("a $\\frac{1}{2$ b") == "<p>a $\\frac{1}{2$ b</p>")
        #expect(html("a $$\\left( x$$ b") == "<p>a $$\\left( x$$ b</p>")
        #expect(html("$`a < {b`$") == "<p>$`a &lt; {b`$</p>")
    }

    @Test("math in a heading anchors by its TeX, as GitHub's anchor reads its text")
    func heading() {
        #expect(html("## The $x^2$ term").hasPrefix("<h2 id=\"the-x2-term\">"))
        #expect(html("## Using $\\alpha$").hasPrefix("<h2 id=\"using-alpha\">"))
    }

    @Test("math in a table cell, a list item and a quote")
    func containers() {
        #expect(
            html("| a |\n|---|\n| $x\\|y$ |").contains(
                "<math><mrow><mi>x</mi><mo stretchy=\"false\">|</mo><mi>y</mi></mrow></math>"
            )
        )
        #expect(html("- item $x$").contains("<li>item <math><mi>x</mi></math></li>"))
        #expect(html("> quote $z$").contains("<p>quote <math><mi>z</mi></math></p>"))
    }

    @Test("a paragraph of dollars costs one look ahead per dollar")
    func manyDollars() {
        let prose = String(repeating: "$HOME and $PATH ", count: 5000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = MarkdownDocument.render(prose) }
        #expect(!html("$HOME and $PATH").contains("<math"))
        #expect(elapsed < .seconds(2))
    }
}
