import Foundation
import Testing

@testable import DirnexCore

/// The HTML writer, and the two walls the milestone rests on (PLAN.md §M18 ▸ Slice 1).
///
/// The escaping section is the one that matters most and is the least interesting to read: it
/// asserts that a `.md` cannot produce an *element*, whatever it contains. A preview renders on
/// cursor movement, so a hole here is a page that runs somebody else's code because the cursor
/// passed over their file.
@Suite("MarkdownDocument")
struct MarkdownRendererTests {
    private func html(_ text: String) -> String {
        MarkdownDocument.render(text).html
    }

    // MARK: - Escaping: the contract

    @Test("raw HTML is text, so a `.md` cannot produce an element")
    func rawHTMLIsEscaped() {
        let source = """
        <script>alert(1)</script>

        <img src="x" onerror="alert(2)">

        <b>bold?</b>
        """
        let rendered = html(source)
        #expect(!rendered.contains("<script"))
        #expect(!rendered.contains("<img"))
        #expect(!rendered.contains("<b>"))
        // The *word* `onerror` survives, and must — it is text the reader is meant to see. What
        // must not survive is the attribute, whose quotes are escaped along with its tag.
        #expect(!rendered.contains("onerror=\""))
        #expect(rendered.contains("onerror=&quot;"))
        // Present, and visible, as the characters the author typed.
        #expect(rendered.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(rendered.contains("&lt;b&gt;bold?&lt;/b&gt;"))
    }

    @Test("a `javascript:` link keeps its words and loses its href")
    func dangerousSchemes() {
        // Valid Markdown, no raw HTML anywhere — which is why escaping alone cannot cover it.
        let rendered = html("[click me](javascript:alert(1))")
        #expect(!rendered.contains("javascript:"))
        #expect(!rendered.contains("<a "))
        #expect(rendered.contains("click me"))
        #expect(html("[x](vbscript:foo)") == "<p>x</p>")
        // Whitespace and control characters inside the scheme do not smuggle it past the test.
        #expect(!html("[x](java\tscript:alert(1))").contains("<a "))
    }

    @Test("the schemes a document has a reason to use still work")
    func allowedSchemes() {
        #expect(html("[a](https://example.com)").contains("href=\"https://example.com\""))
        #expect(html("[a](mailto:x@example.com)").contains("href=\"mailto:x@example.com\""))
        #expect(html("[a](./relative/path.md)").contains("href=\"./relative/path.md\""))
        #expect(html("[a](#anchor)").contains("href=\"#anchor\""))
    }

    @Test("a `data:` URI is allowed for an image and refused for a link")
    func dataURIs() {
        // What a self-contained document inlines, and what M16 measured the content rules to let
        // through. `data:text/html` in a link is a page of somebody else's making.
        #expect(html("![x](data:image/png;base64,AAAA)").contains("<img src=\"data:image/png"))
        #expect(!html("[x](data:text/html,<script>1</script>)").contains("<a "))
    }

    @Test("a refused image renders as its alt text rather than a broken icon")
    func refusedImage() {
        #expect(html("![a description](javascript:x)") == "<p>a description</p>")
    }

    @Test("quotes in a title or an alt cannot break out of the attribute")
    func attributeEscaping() {
        let rendered = html("![\"><script>x</script>](a.png \"ti\\\"tle\")")
        #expect(!rendered.contains("<script"))
        #expect(rendered.contains("&quot;"))
    }

    // MARK: - Blocks

    @Test("headings, paragraphs and rules render as themselves")
    func leafBlocks() {
        // The `id` arrives with Slice 2; `MarkdownAnchorTests` is where the rule that produces it
        // is pinned, and this only states that a heading carries one.
        #expect(html("# Title") == "<h1 id=\"title\">Title</h1>")
        #expect(html("Text.") == "<p>Text.</p>")
        #expect(html("***") == "<hr>")
    }

    @Test("a fence names its language in the class every other tool uses")
    func codeBlocks() {
        // A named language is also *coloured* from Slice 2 on, by M17's scanner — so the plain
        // shape is the one an unclaimed info string keeps.
        #expect(html("```swift\nlet x = 1\n```").hasPrefix("<pre><code class=\"language-swift\">"))
        #expect(html("```\nplain\n```") == "<pre><code>plain\n</code></pre>")
        #expect(html("```nosuchlanguage\nplain\n```")
            == "<pre><code class=\"language-nosuchlanguage\">plain\n</code></pre>")
        // Only the first word: an info string may carry more than the language.
        #expect(html("```swift showLineNumbers\nx\n```").contains("class=\"language-swift\""))
    }

    @Test("a tight list unwraps its paragraphs and a loose one keeps them")
    func listTightness() {
        #expect(html("- a\n- b") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>")
        #expect(html("- a\n\n- b") == "<ul>\n<li><p>a</p></li>\n<li><p>b</p></li>\n</ul>")
    }

    @Test("an ordered list emits `start` only when it is not 1")
    func listStart() {
        #expect(html("1. a") == "<ol>\n<li>a</li>\n</ol>")
        #expect(html("3. a").contains("<ol start=\"3\">"))
    }

    @Test("a task item's checkbox is drawn and disabled")
    func taskList() {
        let rendered = html("- [x] done")
        #expect(rendered.contains("<input type=\"checkbox\" disabled checked>"))
        #expect(rendered.contains("class=\"task\""))
    }

    @Test("a table's alignment is a class, not an inline style")
    func tables() {
        let rendered = html("| a | b |\n| :- | -: |\n| 1 | 2 |")
        #expect(rendered.contains("<th class=\"align-left\">a</th>"))
        #expect(rendered.contains("<th class=\"align-right\">b</th>"))
        #expect(rendered.contains("<tbody>"))
        // Appearance is the app's, so nothing here carries a colour or a length.
        #expect(!rendered.contains("style="))
    }

    @Test("a ragged row is padded to the header's width rather than dropping the table")
    func raggedTable() {
        let rendered = html("| a | b |\n| - | - |\n| 1 |")
        #expect(rendered.contains("<td>1</td><td></td>"))
    }

    @Test("front matter renders as a labelled table")
    func frontMatter() {
        let rendered = html("---\ntitle: A note\n---\n\nBody.")
        #expect(rendered.contains("<table class=\"front-matter\">"))
        #expect(rendered.contains("<th>title</th><td>A note</td>"))
        #expect(rendered.contains("<p>Body.</p>"))
    }

    @Test("a blockquote holds whatever blocks were inside it")
    func blockQuote() {
        #expect(html("> ## Note\n> text")
            == "<blockquote><h2 id=\"note\">Note</h2>\n<p>text</p></blockquote>")
    }

    // MARK: - Inline

    @Test("emphasis, code and breaks reach the page as their elements")
    func inlineElements() {
        #expect(html("*a* **b** ~~c~~ `d`")
            == "<p><em>a</em> <strong>b</strong> <del>c</del> <code>d</code></p>")
        #expect(html("a  \nb") == "<p>a<br>\nb</p>")
    }

    @Test("a link definition written after its use still resolves")
    func referenceDefinitions() {
        let source = """
        See [the plan][plan].

        [plan]: PLAN.md "The plan"
        """
        #expect(html(source) == "<p>See <a href=\"PLAN.md\" title=\"The plan\">the plan</a>.</p>")
    }

    /// The seam PLAN.md §M18's first probe lands in: how a generated document reaches a sibling
    /// file is a WebKit question, and the core must not have an opinion about it. The default is
    /// identity, so every other test in this file renders the source the file wrote.
    @Test("the image resolver is the app's, and the core's default changes nothing")
    func imageResolver() {
        #expect(html("![x](img/a.png)").contains("src=\"img/a.png\""))
        let options = MarkdownRenderOptions { "data:image/png;base64,\($0.count)" }
        let rendered = MarkdownDocument.render("![x](img/a.png)", options: options).html
        #expect(rendered.contains("src=\"data:image/png;base64,9\""))
    }

    /// The resolver's answer is what lands in the `src`, so it is the string the scheme allow-list
    /// has to be asked about — sanitizing the source *before* resolving would check a URL the page
    /// never sees. A resolver that returned `javascript:` would otherwise walk straight through.
    @Test("a resolver cannot smuggle a scheme past the allow-list")
    func resolverOutputIsSanitized() {
        let options = MarkdownRenderOptions { _ in "javascript:alert(1)" }
        let rendered = MarkdownDocument.render("![alt words](img/a.png)", options: options).html
        #expect(!rendered.contains("javascript:"))
        #expect(!rendered.contains("<img"))
        // Refused sources keep the author's own description of the picture.
        #expect(rendered.contains("alt words"))
    }

    @Test("an empty document renders to nothing")
    func empty() {
        #expect(html("").isEmpty)
    }
}
