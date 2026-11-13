import Foundation
import Testing

@testable import DirnexCore

/// Wiki links, `[[name]]` (PLAN.md §M39 ▸ Slice 7).
///
/// The real ones on this Mac are Claude's memory notes, each naming a sibling `.md`; the brackets
/// that are *not* links are JavaScript READMEs' `[[Prototype]]` and changelogs' `[[#4995]](url)`.
/// Both shapes are pinned here.
@Suite("Markdown wiki links")
struct MarkdownWikiLinkTests {
    /// The page, with `files` as everything beside the document.
    private func html(_ text: String, files: Set<String> = []) -> String {
        MarkdownDocument.render(
            text,
            options: MarkdownRenderOptions(locateFile: { files.contains($0) ? $0 : nil })
        ).html
    }

    @Test("a name is a link to the note beside the document, `.md` added")
    func sibling() {
        #expect(
            html("See [[dirnex-project-goal]].", files: ["dirnex-project-goal.md"])
                == "<p>See <a href=\"dirnex-project-goal.md\">dirnex-project-goal</a>.</p>"
        )
    }

    @Test("a name whose file is not there stays the text it was written as")
    func missing() {
        #expect(
            html("Robustly get the [[Prototype]] of an object.")
                == "<p>Robustly get the [[Prototype]] of an object.</p>"
        )
        #expect(
            html("reduce observable [[Get]]s", files: ["Other.md"])
                == "<p>reduce observable [[Get]]s</p>"
        )
        // The renderer's own default: no say from the app, no wiki links.
        #expect(
            MarkdownDocument.render("[[note]]").html == "<p>[[note]]</p>"
        )
    }

    @Test("text after `|` is drawn, and a heading becomes the anchor it will carry")
    func labelAndHeading() {
        #expect(
            html("[[My Note#Getting Started|start here]]", files: ["My Note.md"])
                == "<p><a href=\"My%20Note.md#getting-started\">start here</a></p>"
        )
        // Obsidian nests headings; the last one is where to land.
        #expect(
            html("[[guide#Install#On a Mac]]", files: ["guide.md"])
                == "<p><a href=\"guide.md#on-a-mac\">guide#Install#On a Mac</a></p>"
        )
        #expect(
            html("[[ guide | the guide ]]", files: ["guide.md"])
                == "<p><a href=\"guide.md\">the guide</a></p>"
        )
    }

    @Test("`[[#Heading]]` links into the document, when the document has that heading")
    func sameDocument() {
        let rendered = html("## Usage\n\nSee [[#Usage]] and [[#Nowhere]].")
        #expect(rendered == """
        <h2 id="usage">Usage</h2>
        <p>See <a href="#usage">#Usage</a> and [[#Nowhere]].</p>
        """)
    }

    @Test("a note is tried before the name as written, and each path is asked about once")
    func candidates() {
        #expect(MarkdownWikiLink.candidates(for: "note") == ["note.md", "note"])
        #expect(MarkdownWikiLink.candidates(for: "diagram.png") == ["diagram.png.md", "diagram.png"])
        #expect(MarkdownWikiLink.candidates(for: "Guide.MD") == ["Guide.MD"])
        #expect(html("[[LICENSE]]", files: ["LICENSE"]) == "<p><a href=\"LICENSE\">LICENSE</a></p>")

        var asked: [String] = []
        let lookup = MarkdownWikiLink.Lookup(
            locateFile: { path in
                asked.append(path)
                return path == "note.md" ? path : nil
            },
            anchors: []
        )
        let nodes = MarkdownInlineParser.parse(
            "[[note]] [[note]] [[diagram.png]]",
            wikiLinks: lookup
        )
        #expect(asked == ["note.md", "diagram.png.md", "diagram.png"])
        #expect(nodes.first == .link(destination: "note.md", title: nil, children: [.text("note")]))
    }

    @Test("the href is a relative path Slice 4's resolver reads back to the file")
    func resolvesBack() throws {
        let names = ["Notes: May", "100% done", "café", "a#b"]
        let document = VFSPath.local("/Users/someone/notes/index.md")
        for name in names {
            let reference = try #require(MarkdownWikiLink.parse(name))
            // `#` opens the heading, as Obsidian reads it.
            let file = reference.name + ".md"
            let rendered = html("[[\(name)]]", files: [file])
            let href = try #require(rendered.firstMatch(of: /href="([^"]*)"/)?.1)
            let fragment = reference.heading.map(MarkdownSlug.slug(for:))
            #expect(
                DocumentLink.resolve(String(href), from: document)
                    == .location(.local("/Users/someone/notes/" + file), fragment: fragment),
                "\(name) → \(href)"
            )
        }
    }

    @Test("the href spells the file as the app found it, so the click lands on its row")
    func spelling() {
        let rendered = MarkdownDocument.render(
            "[[Note]] and [[Note|again]]",
            options: MarkdownRenderOptions(locateFile: { $0 == "Note.md" ? "note.md" : nil })
        ).html
        #expect(rendered == "<p><a href=\"note.md\">Note</a> and <a href=\"note.md\">again</a></p>")
    }

    @Test("a path in the name is relative to the document, and one from a vault's root is text")
    func paths() {
        #expect(
            html("[[sub/deep note]]", files: ["sub/deep note.md"])
                == "<p><a href=\"sub/deep%20note.md\">sub/deep note</a></p>"
        )
        #expect(html("[[/root note]]", files: ["/root note.md"]) == "<p>[[/root note]]</p>")
    }

    @Test("a link with bracketed text, a code span and an escape all win over a wiki link")
    func neighbours() {
        let files: Set<String> = ["0.1.0.md", "note.md", "4995.md"]
        #expect(
            html("* [[0.1.0]](#010)", files: files)
                == "<ul>\n<li><a href=\"#010\">[0.1.0]</a></li>\n</ul>"
        )
        #expect(
            html("[[#4995]](https://example.com/pull/4995) Add a flag", files: files)
                == "<p><a href=\"https://example.com/pull/4995\">[#4995]</a> Add a flag</p>"
        )
        #expect(html("`[[note]]`", files: files) == "<p><code>[[note]]</code></p>")
        #expect(html("\\[[note]]", files: files) == "<p>[[note]]</p>")
        #expect(html("[[a] note]]", files: files) == "<p>[[a] note]]</p>")
        #expect(html("[[note\nmore]]", files: files) == "<p>[[note\nmore]]</p>")
        #expect(html("[[]] and [[|x]]", files: files) == "<p>[[]] and [[|x]]</p>")
    }

    @Test("a link's own text reads no wiki link, so no link is drawn inside one")
    func insideLink() {
        #expect(
            html("[see [[note]]](other.md)", files: ["note.md"])
                == "<p><a href=\"other.md\">see [[note]]</a></p>"
        )
    }

    @Test("a table cell carries `|` escaped, as Obsidian writes an aliased link in one")
    func tableCell() {
        let rendered = html("| Link |\n| --- |\n| [[note\\|the note]] |", files: ["note.md"])
        #expect(rendered.contains("<td><a href=\"note.md\">the note</a></td>"))
    }

    @Test("a heading draws the link and anchors as its text is written, as GitHub anchors it")
    func heading() {
        let rendered = html("## See [[note|Label]]\n\n[[_TOC_]]", files: ["note.md"])
        #expect(rendered.hasPrefix(
            "<h2 id=\"see-notelabel\">See <a href=\"note.md\">Label</a></h2>"
        ))
        #expect(rendered.contains("href=\"#see-notelabel\""))
    }
}
