import Foundation
import Testing

@testable import DirnexCore

/// A rendered page saved as a file (PLAN.md §M39 ▸ Slice 11): the name it is offered under, the
/// title it carries, and the document around it.
@Suite("Markdown export")
struct MarkdownExportTests {
    private func name(_ source: String, _ format: MarkdownExport.Format = .html) -> String {
        MarkdownExport.fileName(forSource: source, as: format)
    }

    private func title(_ text: String) -> String? {
        MarkdownDocument.render(text).title
    }

    private func document(title: String = "T", stylesheet: String = "", body: String = "") -> String {
        String(
            data: MarkdownExport.htmlDocument(title: title, stylesheet: stylesheet, body: body),
            encoding: .utf8
        ) ?? ""
    }

    // MARK: - The name

    @Test("the last extension gives way to the format's", arguments: [
        ("README.md", "README.html", "README.pdf"),
        ("notes.markdown", "notes.html", "notes.pdf"),
        ("My Doc.MARKDOWN", "My Doc.html", "My Doc.pdf"),
        ("a.b.md", "a.b.html", "a.b.pdf"),
        ("名前.md", "名前.html", "名前.pdf"),
        ("README", "README.html", "README.pdf"),
        (".notes.md", ".notes.html", ".notes.pdf"),
        // A dotfile has no extension to drop, and a last dot followed by a space starts none.
        (".md", ".md.html", ".md.pdf"),
        ("a b.c d", "a b.c d.html", "a b.c d.pdf")
    ])
    func names(source: String, html: String, pdf: String) {
        #expect(name(source, .html) == html)
        #expect(name(source, .pdf) == pdf)
    }

    @Test("a name at the limit loses the end of its stem, and one under it loses nothing")
    func asciiLimit() {
        let long = String(repeating: "a", count: 252) + ".md"
        #expect(name(long, .html) == String(repeating: "a", count: 250) + ".html")
        #expect(name(long, .pdf) == String(repeating: "a", count: 251) + ".pdf")
        let fits = String(repeating: "a", count: 250) + ".md"
        #expect(name(fits, .html) == String(repeating: "a", count: 250) + ".html")
        // No extension to give back, so the name grows by all five.
        let bare = String(repeating: "a", count: 253)
        #expect(name(bare, .html) == String(repeating: "a", count: 250) + ".html")
    }

    @Test("bytes count only when the source kept to 255 of them")
    func bytesWhereTheSourceKeptToThem() {
        // 255 bytes and 129 units: the source fits a server that counts bytes, so the export does.
        let atByteLimit = String(repeating: "é", count: 126) + ".md"
        #expect(atByteLimit.utf8.count == 255)
        let exported = name(atByteLimit)
        #expect(exported == String(repeating: "é", count: 125) + ".html")
        #expect(exported.utf8.count == 255)
        // 403 bytes: the source came from a disk that counts units, and the export keeps every `é`.
        let pastByteLimit = String(repeating: "é", count: 200) + ".md"
        #expect(name(pastByteLimit) == String(repeating: "é", count: 200) + ".html")
    }

    @Test("whole characters go, so an emoji or a flag is never cut in half")
    func wholeCharacters() {
        let faces = String(repeating: "😀", count: 126) + ".md"
        #expect(faces.utf16.count == 255)
        #expect(name(faces) == String(repeating: "😀", count: 125) + ".html")
        let flags = String(repeating: "🇩🇪", count: 63) + ".md"
        #expect(flags.utf16.count == 255)
        #expect(name(flags) == String(repeating: "🇩🇪", count: 62) + ".html")
    }

    @Test("a single character too long to fit is cut between its scalars")
    func oneHugeCharacter() {
        let marks = String(repeating: "\u{0301}", count: 251)
        let source = "e" + marks + ".md"
        #expect(source.count == 4)
        #expect(source.utf16.count == 255)
        let exported = name(source)
        #expect(exported == "e" + String(repeating: "\u{0301}", count: 249) + ".html")
        #expect(exported.utf16.count == 255)
    }

    // MARK: - The title

    @Test("front matter's title comes first")
    func frontMatterTitle() {
        #expect(title("---\ntitle: Front Title\n---\n\n# Heading") == "Front Title")
        #expect(title("---\ntitle: \"Quoted: yes\"\n---\n\n# Heading") == "Quoted: yes")
        #expect(title("---\nTitle: Cased\n---\n\nText") == "Cased")
        #expect(title("---\nlayout: post\ntitle:   Spaced    out\n---\n") == "Spaced out")
    }

    @Test("a front-matter title that names nothing gives way to the heading")
    func emptyFrontMatterTitle() {
        // `''` is in the corpus 4 times.
        #expect(title("---\ntitle: ''\n---\n\n# Heading") == "Heading")
        #expect(title("---\ntitle:\n---\n\n# Heading") == "Heading")
        // Folded YAML: its text is on the lines below, which front matter reads as rows of their own.
        #expect(title("---\ntitle: >-\n  Folded text\n---\n\n# Heading") == "Heading")
        #expect(title("---\ntitle: |\n  Literal\n---\n\nText") == nil)
    }

    @Test("the first heading is the title when it is level 1")
    func firstHeading() {
        #expect(title("# Project\n\nText.") == "Project")
        #expect(title("Badges here.\n\n# Project\n\n## Install") == "Project")
        #expect(title("Project\n=======\n\nText.") == "Project")
        #expect(title("> # Quoted\n\nText.") == "Quoted")
    }

    @Test("a later level-1 heading is no title, as in a release changelog")
    func laterLevelOne() {
        #expect(title("## Unreleased\n\n# [3.4.0](https://example.com/compare)\n") == nil)
        #expect(title("Just a paragraph.") == nil)
        #expect(title("") == nil)
    }

    @Test("the heading's text as the page draws it, shortcodes included")
    func headingText() {
        #expect(title("# :rocket: Launch `code` *now*") == "🚀 Launch code now")
        #expect(title("# [Dirnex](https://example.com) docs") == "Dirnex docs")
        #expect(title("# The $x^2$ term") == "The x^2 term")
        #expect(title("# 10:30:00 :smile:") == "10:30:00 :smile:")
        // Run by run, as the heading draws them: a code span keeps its shortcode as typed.
        #expect(title("# Use `:smile:` here") == "Use :smile: here")
    }

    @Test("a badge or a logo in the heading is no word of the title", arguments: [
        (
            "# Awesome Compose [![Awesome](https://awesome.re/badge.svg)](https://awesome.re)",
            "Awesome Compose"
        ),
        (
            "# caniuse-api [![Build Status](https://a/b.svg)](https://a) ![Build status](https://c.svg)",
            "caniuse-api"
        ),
        ("# ![Logo](logo.png) Project", "Project")
    ])
    func images(heading: String, expected: String) {
        #expect(title(heading) == expected)
    }

    @Test("a run read as an HTML tag is no word of the title, as GitHub draws it", arguments: [
        (
            "# PostCSS Lab Function <img src=\"https://postcss.github.io/postcss/logo.svg\" "
                + "alt=\"PostCSS Logo\" width=\"90\" height=\"90\" align=\"right\">",
            "PostCSS Lab Function"
        ),
        (
            "# is-bigint <sup>[![Version Badge][2]][1]</sup>\n\n[1]: https://a\n[2]: https://b.svg",
            "is-bigint"
        ),
        ("# Embedded JavaScript templates<br/>", "Embedded JavaScript templates"),
        ("# Title <!-- note --->", "Title"),
        ("# Vec<String> and </b >x", "Vec and x"),
        // `*y*` is emphasis, inside a tag that is still one tag.
        ("# x <a title=\"*y*\">z</a>", "x z")
    ])
    func tags(heading: String, expected: String) {
        #expect(title(heading) == expected)
    }

    @Test("what only looks like a tag stays, and so does a tag in code", arguments: [
        ("# a < b > c", "a < b > c"),
        ("# 1 <2 and <>", "1 <2 and <>"),
        ("# <a title=\"open", "<a title=\"open"),
        ("# <!-- open", "<!-- open"),
        (
            "# Portfolio mode (`--portfolio <parent-dir>`)",
            "Portfolio mode (--portfolio <parent-dir>)"
        )
    ])
    func notTags(heading: String, expected: String) {
        #expect(title(heading) == expected)
    }

    @Test("a heading that is nothing but a picture names nothing, and the stem stands in")
    func pictureOnly() {
        let render = MarkdownDocument.render(
            "# <img src=\"media/header.png\" width=\"1000\">\n\nText."
        )
        #expect(render.title == nil)
        #expect(MarkdownExport.title(of: render, sourceName: "readme.md") == "readme")
    }

    @Test("with no title of its own, a page takes its file's stem")
    func fallback() {
        let untitled = MarkdownDocument.render("Text.")
        #expect(MarkdownExport.title(of: untitled, sourceName: "notes.md") == "notes")
        #expect(MarkdownExport.title(of: untitled, sourceName: "README") == "README")
        let titled = MarkdownDocument.render("# Project")
        #expect(MarkdownExport.title(of: titled, sourceName: "notes.md") == "Project")
    }

    // MARK: - The document

    @Test("a whole document: charset first, then the policy, the title, the style and the body")
    func structure() {
        let page = document(title: "Project", stylesheet: "body { color: red; }", body: "<p>Hi</p>")
        #expect(page == """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" \
        content="script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Project</title>
        <style>
        body { color: red; }
        </style>
        </head>
        <body>
        <p>Hi</p>
        </body>
        </html>

        """)
    }

    @Test("the title is escaped, and its whitespace drawn as a tab draws it")
    func titleEscaped() {
        let page = document(title: "A & <B>\n   \"c\" 'd'")
        #expect(page.contains("<title>A &amp; &lt;B&gt; &quot;c&quot; &#39;d&#39;</title>"))
    }

    @Test("the policy stops scripts and leaves pictures and styles alone")
    func policy() {
        let policy = MarkdownExport.contentSecurityPolicy
        for directive in ["script-src 'none'", "object-src 'none'", "base-uri 'none'"] {
            #expect(policy.contains(directive))
        }
        // A remote image keeps working (Oleg, 2026-11-14), so nothing may fall back to `none`.
        #expect(!policy.contains("default-src"))
        #expect(!policy.contains("img-src"))
        #expect(!policy.contains("style-src"))
        // An attribute value in double quotes, written as it stands.
        #expect(!policy.contains("\""))
        #expect(!policy.contains("&"))
    }

    @Test("the bytes are UTF-8, as the file says")
    func utf8() {
        let body = "<p>é 漢 😀</p>"
        let data = MarkdownExport.htmlDocument(title: "名前 😀", stylesheet: "", body: body)
        let text = String(data: data, encoding: .utf8)
        #expect(text?.contains(body) == true)
        #expect(text?.contains("<title>名前 😀</title>") == true)
        #expect(data.count == text?.utf8.count)
        // A browser looks for the charset in the first 1 024 bytes.
        #expect(data.prefix(1024).range(of: Data("<meta charset=\"utf-8\">".utf8)) != nil)
    }

    @Test("the wrapper names nothing to load")
    func wrapperLoadsNothing() {
        let page = document(title: "https://example.com/x.png")
        for reference in ["src=", "href=", "url(", "@import", "<link", "<script", "<base"] {
            #expect(!page.contains(reference), "\(reference)")
        }
    }

    @Test(
        "an exported page holds what the preview drew: inlined images, remote ones, links as written"
    )
    func exportedPage() {
        let inline = "data:image/png;base64,iVBORw0KGgo="
        let options = MarkdownRenderOptions(resolveImageSource: { $0 == "pic.png" ? inline : $0 })
        let render = MarkdownDocument.render("""
        # Guide

        ![local](pic.png) ![badge](https://example.com/badge.svg) ![outside](../logo.png)

        See [the next part](other.md#part) and [above](#guide).
        """, options: options)
        let page = document(
            title: MarkdownExport.title(of: render, sourceName: "guide.md"),
            body: render.html
        )
        #expect(page.contains("<title>Guide</title>"))
        #expect(page.contains("src=\"\(inline)\""))
        #expect(page.contains("src=\"https://example.com/badge.svg\""))
        // The resolver left it alone, as the preview's does for a source outside the folder.
        #expect(page.contains("src=\"../logo.png\""))
        #expect(page.contains("href=\"other.md#part\""))
        #expect(page.contains("href=\"#guide\""))
    }
}
