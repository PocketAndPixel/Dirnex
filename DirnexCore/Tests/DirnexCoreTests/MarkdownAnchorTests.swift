import Foundation
import Testing

@testable import DirnexCore

/// Heading anchors, `[[_TOC_]]` and coloured fences (PLAN.md §M18 ▸ Slice 2).
///
/// The slug cases are not invented: each one is a shape that appeared in the 211-file corpus the
/// rule was probed against (`MarkdownSlug`), and the two that look like bugs — a leading hyphen from
/// a dropped emoji, a trailing one from a trailing emoji — are the two the probe proved are right.
@Suite("Markdown anchors")
struct MarkdownAnchorTests {
    private func html(_ text: String) -> String {
        MarkdownDocument.render(text).html
    }

    private func headings(_ text: String) -> [MarkdownHeading] {
        MarkdownBlockParser.scan(text).headings
    }

    // MARK: - The slug rule

    @Test("lowercased, spaces to hyphens, punctuation dropped")
    func slugBasics() {
        #expect(MarkdownSlug.slug(for: "Product goals") == "product-goals")
        #expect(MarkdownSlug.slug(for: "Cross-cutting: testing strategy")
            == "cross-cutting-testing-strategy")
        #expect(MarkdownSlug.slug(for: "What's new (2026)?") == "whats-new-2026")
        // `-` and `_` are the two punctuation marks that survive.
        #expect(MarkdownSlug.slug(for: "snake_case and kebab-case") == "snake_case-and-kebab-case")
    }

    @Test("nothing is trimmed, which is what makes an emoji heading's real anchor work")
    func slugKeepsEdgeHyphens() {
        // Both spellings resolve real links in the probe corpus. Tidying them away is the obvious
        // improvement and breaks every document that carries one.
        #expect(MarkdownSlug.slug(for: "🐛 Bugs") == "-bugs")
        #expect(MarkdownSlug.slug(for: "Contributors ✨") == "contributors-")
    }

    @Test("an em dash goes, and a non-Latin heading keeps its letters")
    func slugDropsSymbolsNotLetters() {
        // An em dash is punctuation, so it leaves and its two spaces become two hyphens — which is
        // why this repo's own headings slug with a doubled hyphen.
        #expect(MarkdownSlug.slug(for: "In flight — M18") == "in-flight--m18")
        #expect(MarkdownSlug.slug(for: "Инженерные заметки") == "инженерные-заметки")
        #expect(MarkdownSlug.slug(for: "型と値") == "型と値")
    }

    @Test("a heading with nothing sluggable in it gets no anchor at all")
    func emptySlug() {
        #expect(MarkdownSlug.slug(for: "!!!").isEmpty)
        // No `id=""`, which is a broken attribute rather than a usable one.
        #expect(html("# !!!") == "<h1>!!!</h1>")
    }

    @Test("duplicates are suffixed, and the counter steps past a collision the author wrote")
    func duplicateSlugs() {
        var slugger = MarkdownSlugger()
        #expect(slugger.next(for: "Usage") == "usage")
        #expect(slugger.next(for: "Usage") == "usage-1")
        #expect(slugger.next(for: "Usage") == "usage-2")
        // The shape the probe found in a real file linking to `#all`, `#all-1` *and* `#all-2`: an
        // explicitly written `All 1` takes `all-1`, so the next `All` has to keep counting.
        var collision = MarkdownSlugger()
        #expect(collision.next(for: "All") == "all")
        #expect(collision.next(for: "All 1") == "all-1")
        #expect(collision.next(for: "All") == "all-2")
    }

    // MARK: - Anchors in the page

    @Test("the anchor is built from the heading's text, not its markup")
    func slugIgnoresInlineMarkup() {
        #expect(html("# The `Panel` **value** type")
            .hasPrefix("<h1 id=\"the-panel-value-type\">"))
        // A link's text counts; its destination does not.
        #expect(html("# See [the plan](PLAN.md)").hasPrefix("<h1 id=\"see-the-plan\">"))
    }

    @Test("a heading anywhere in the document is anchored, in render order")
    func nestedHeadings() {
        // The one invariant `MarkdownHeadings` cannot get from the type system: it walks the block
        // tree to gather the anchors, the renderer walks it again to emit them, and the two orders
        // have to agree. Containers on both sides, and a duplicate title so an off-by-one shows.
        let source = """
        # Top

        > ## Quoted

        - ### In a list
        - ### In a list

        ## Top
        """
        let gathered = headings(source)
        #expect(gathered.map(\.slug) == ["top", "quoted", "in-a-list", "in-a-list-1", "top-1"])
        let emitted = Self.ids(in: html(source))
        #expect(emitted == gathered.map(\.slug))
    }

    @Test("a `#` inside a fence is code, and gets no anchor")
    func fencedHashIsNotAHeading() {
        #expect(headings("```\n# not a heading\n```").isEmpty)
    }

    // MARK: - `[[_TOC_]]`

    @Test("both spellings are recognized, alone on their line")
    func tocMarker() {
        #expect(html("[[_TOC_]]\n\n# A").contains("<nav class=\"toc\">"))
        #expect(html("[TOC]\n\n# A").contains("<nav class=\"toc\">"))
        #expect(html("[[_toc_]]\n\n# A").contains("<nav class=\"toc\">"))
        // Inside a sentence it is a link somebody wrote, not a request for an outline.
        #expect(!html("See [TOC] below.\n\n# A").contains("<nav"))
        // And inside a fence it is the literal text the fence exists to show. Doing this in the
        // block pass is what makes that true for free.
        #expect(!html("```\n[[_TOC_]]\n```\n\n# A").contains("<nav"))
    }

    @Test("the outline nests by heading level")
    func tocNesting() {
        let rendered = html("[[_TOC_]]\n\n# A\n\n## B\n\n### C\n\n## D\n\n# E")
        let nav = Self.nav(in: rendered)
        // A(1) → B(2) → C(3) → back to D(2) → back to E(1).
        #expect(nav.contains("<a href=\"#a\">A</a>"))
        #expect(nav.filter { $0 == "<" }.isEmpty == false)
        #expect(Self.listDepth(in: nav) == 3)
        #expect(Self.balanced(nav))
    }

    @Test("a level jump nests one step, and a document that starts deep still nests")
    func tocRaggedLevels() {
        #expect(Self.listDepth(in: Self.nav(in: html("[[_TOC_]]\n\n# A\n\n### C"))) == 2)
        #expect(Self.balanced(Self.nav(in: html("[[_TOC_]]\n\n## A\n\n### B\n\n# C"))))
        #expect(Self.balanced(Self.nav(in: html("[[_TOC_]]\n\n#### A\n\n# B\n\n### C\n\n## D"))))
    }

    @Test("an entry draws the heading's text, escaped, and never its markup")
    func tocEntryText() {
        // A heading holding a link would otherwise put an `<a>` inside the entry's own.
        let nav = Self.nav(in: html("[[_TOC_]]\n\n# See [docs](x.md) & `code`"))
        #expect(nav.contains(">See docs &amp; code</a>"))
        #expect(!nav.contains("x.md"))
    }

    @Test("a marker in a document with no headings renders as nothing")
    func tocWithoutHeadings() {
        #expect(html("[[_TOC_]]\n\nJust prose.") == "\n<p>Just prose.</p>")
    }

    // MARK: - Coloured fences

    @Test("a fence's tokens are spans of the kind M17's scanner named")
    func fenceSpans() {
        let rendered = html("```swift\nlet name = \"x\" // 1\n```")
        #expect(rendered.contains("<span class=\"tok-keyword\">let</span>"))
        #expect(rendered.contains("<span class=\"tok-string\">&quot;x&quot;</span>"))
        #expect(rendered.contains("<span class=\"tok-comment\">// 1</span>"))
        // The text between the spans is still there, and still escaped.
        #expect(rendered.contains("name = "))
    }

    @Test("an unclaimed info string leaves the fence plain")
    func unknownLanguage() {
        #expect(!html("```brainfuck\n+++\n```").contains("<span"))
        #expect(!html("```\nlet x = 1\n```").contains("<span"))
    }

    @Test("escaping survives highlighting, inside a span and out")
    func fenceEscaping() {
        let rendered = html("```html\n<script>alert(1)</script>\n```")
        #expect(!rendered.contains("<script"))
        #expect(rendered.contains("&lt;"))
        // The tag name is a `typeOrTag` to the markup scanner, so the span is *around* escaped text
        // rather than around a real element.
        #expect(rendered.contains("<span class=\"tok-type\">"))
    }

    @Test("a token slice never splits the text it stands for")
    func fenceUnicode() {
        // Non-BMP characters are two UTF-16 units, which is the unit the tokens are measured in.
        // A slice taken in the wrong unit would corrupt the string rather than fail.
        let rendered = html("```swift\nlet emoji = \"👩‍💻🚀\" // 🐛\n```")
        #expect(rendered.contains("👩‍💻🚀"))
        #expect(rendered.contains("🐛"))
        #expect(!rendered.contains("\u{FFFD}"))
    }

    @Test("an indented code block has no info string and stays plain")
    func indentedCode() {
        #expect(!html("    let x = 1").contains("<span"))
    }

    // MARK: - Helpers

    /// Every `id` in a fragment, in document order.
    private static func ids(in html: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(html)
        while let start = rest.range(of: " id=\"") {
            rest = rest[start.upperBound...]
            let value = rest.prefix { $0 != "\"" }
            ids.append(String(value))
            rest = rest[value.endIndex...]
        }
        return ids
    }

    private static func nav(in html: String) -> String {
        guard let start = html.range(of: "<nav"), let end = html.range(of: "</nav>") else {
            return ""
        }
        return String(html[start.lowerBound..<end.upperBound])
    }

    /// The deepest run of open `<ul>`s, which is what "nested" means here.
    private static func listDepth(in html: String) -> Int {
        var depth = 0
        var deepest = 0
        var rest = Substring(html)
        while let next = rest.firstIndex(of: "<") {
            rest = rest[rest.index(after: next)...]
            if rest.hasPrefix("ul>") {
                depth += 1
                deepest = max(deepest, depth)
            } else if rest.hasPrefix("/ul>") {
                depth -= 1
            }
        }
        return deepest
    }

    /// Whether every `<ul>` and `<li>` closes in the order it opened. The corpus suite makes the
    /// same check over whole documents; this one exists so a ragged outline can be checked on its
    /// own, where the failure names the heading levels that produced it.
    private static func balanced(_ html: String) -> Bool {
        var stack: [Substring] = []
        var rest = Substring(html)
        while let next = rest.firstIndex(of: "<") {
            rest = rest[rest.index(after: next)...]
            let isClosing = rest.first == "/"
            let name = (isClosing ? rest.dropFirst() : rest).prefix { $0.isLetter }
            guard name == "ul" || name == "li" else { continue }
            if isClosing {
                guard stack.last == name else { return false }
                stack.removeLast()
            } else {
                stack.append(name)
            }
        }
        return stack.isEmpty
    }
}
