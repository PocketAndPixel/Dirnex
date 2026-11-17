import Foundation
import Testing

@testable import DirnexCore

/// The title an exported page carries (PLAN.md §M39 ▸ Slice 11): front matter's, or the words of a
/// first heading at level 1, or the file's stem. Out of `MarkdownExportTests` for SwiftLint's
/// `type_body_length`.
@Suite("Markdown title")
struct MarkdownTitleTests {
    private func title(_ text: String) -> String? {
        MarkdownDocument.render(text).title
    }

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
}
