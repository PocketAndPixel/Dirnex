import Foundation
import Testing

@testable import DirnexCore

/// Slice 1's exit criterion: this repository's own documents (PLAN.md §M18).
///
/// The corpus **is** the target — the milestone deliberately does not chase CommonMark's test suite
/// (PLAN.md §6), so what stands in for it is real files that are read every day. `docs/NOTES.md` is
/// the hardest of them by a distance: lists nested five deep, tables whose cells hold inline code,
/// code fences quoting Markdown at itself, and prose full of the punctuation every one of these
/// constructs is made of.
///
/// The assertions are **structural**, not golden. A golden file would fail on every edit to the
/// documents and say nothing about the renderer; these say the things that have to stay true — the
/// output is well-formed, it invents no tags, and it loses no headings.
@Suite("Markdown corpus")
struct MarkdownCorpusTests {
    /// The repository root, from this file's own path. `#filePath` is baked in at compile time, so
    /// it is right under `swift test` and under `xcodebuild` alike — unlike a bundle resource,
    /// which would mean copying the documents and testing the copy.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let documents = ["PLAN.md", "README.md", "docs/NOTES.md", "docs/HISTORY.md"]

    /// Void elements, which close themselves. Everything else has to be balanced.
    private static let voidTags: Set<String> = ["br", "hr", "img", "input"]

    /// Every tag the renderer is allowed to emit. A closed set on purpose: the day a new one
    /// appears here it is because somebody added it deliberately, and the *page* has to be styled
    /// for it. An open set would let an escaping bug write a tag and call it output.
    private static let allowedTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "p", "hr", "pre", "code", "blockquote",
        "ul", "ol", "li", "input", "table", "thead", "tbody", "tr", "th", "td",
        "em", "strong", "del", "a", "img", "br",
        // Slice 2: `nav` is `[[_TOC_]]`'s outline, `span` is one token of a coloured fence.
        "nav", "span"
    ]

    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    /// Every attribute the renderer is allowed to write. Closed for the same reason the tags are —
    /// and this is the set that catches an event handler, which no search of the *text* can.
    private static let allowedAttributes: Set<String> = [
        "class", "href", "title", "src", "alt", "start", "colspan", "type", "disabled", "checked",
        // Slice 2: a heading's anchor.
        "id"
    ]

    private func source(_ name: String) throws -> String {
        let url = Self.root.appending(path: name)
        // Gated on the file rather than on an environment variable (docs/NOTES.md): `xcodebuild`
        // forwards no shell environment to the test runner.
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "\(name) not found at \(url.path)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test(
        "every document renders, and every tag in the output is one we chose to emit",
        arguments: documents
    )
    func rendersWithKnownTags(_ name: String) throws {
        let html = MarkdownDocument.render(try source(name)).html
        #expect(!html.isEmpty)
        let tags = Set(Self.tags(in: html).map(\.name))
        #expect(tags.subtracting(Self.allowedTags).isEmpty)
    }

    @Test("every document's output is balanced", arguments: documents)
    func balanced(_ name: String) throws {
        let html = MarkdownDocument.render(try source(name)).html
        var stack: [String] = []
        for tag in Self.tags(in: html) where !Self.voidTags.contains(tag.name) {
            if tag.isClosing {
                #expect(
                    stack.last == tag.name,
                    "\(name): </\(tag.name)> closes \(stack.last ?? "nothing")"
                )
                if stack.last == tag.name { stack.removeLast() }
            } else {
                stack.append(tag.name)
            }
        }
        #expect(stack.isEmpty, "\(name): unclosed \(stack)")
    }

    @Test(
        "no document produces a script, a style or an attribute we did not choose",
        arguments: documents
    )
    func inert(_ name: String) throws {
        let html = MarkdownDocument.render(try source(name)).html
        // These two are safe to search for as *text*, and only because escaping makes them
        // unrepresentable: a `<` in prose renders as `&lt;`, so a literal `<script` in the output
        // could only have been written by the renderer.
        #expect(!html.localizedCaseInsensitiveContains("<script"))
        #expect(!html.localizedCaseInsensitiveContains("<style"))
        let tags = Self.tags(in: html)
        // The attributes are a closed set for the same reason the tags are, and it is this that
        // catches an event handler — `onerror` as a *word* is legitimate prose (PLAN.md contains
        // one), so searching the text for it says nothing about whether it reached a tag.
        #expect(Set(tags.flatMap(\.attributes.keys)).subtracting(Self.allowedAttributes).isEmpty)
        // And the same lesson one level down, learned from this very file: PLAN.md discusses
        // `javascript:` links in prose, so the string is in the *text* of a document that is
        // perfectly safe. What matters is the scheme of an attribute somebody could click.
        for tag in tags {
            for key in ["href", "src"] {
                guard let value = tag.attributes[key], let scheme = Self.scheme(of: value) else {
                    continue
                }
                #expect(Self.allowedSchemes.contains(scheme), "\(name): \(key)=\"\(value)\"")
            }
        }
    }

    /// A URL's scheme, read the way a browser would: everything before the first `:`, provided
    /// nothing that ends a scheme comes first. Written here rather than borrowed from `MarkdownURL`
    /// on purpose — a test that reuses the code under test to check the code under test proves the
    /// two agree, not that either is right.
    private static func scheme(of url: String) -> String? {
        var scheme = ""
        for character in url {
            if character == ":" { return scheme.lowercased() }
            guard character.isLetter || character.isNumber || "+-.".contains(character) else {
                return nil
            }
            scheme.append(character)
        }
        return nil
    }

    private static let allowedSchemes: Set<String> = [
        "http", "https", "mailto", "ftp", "ftps", "file", "tel", "sftp", "data"
    ]

    @Test("no heading is lost on the way through", arguments: documents)
    func headingsSurvive(_ name: String) throws {
        let text = try source(name)
        let expected = Self.atxHeadingCount(in: text)
        // `h1`…`h6` by name, not "starts with h and is two characters": `hr` is two characters and
        // starts with an h, and PLAN.md's two thematic breaks counted as headings until this said
        // what it meant.
        let rendered = Self.tags(in: MarkdownDocument.render(text).html)
            .filter { !$0.isClosing && Self.headingTags.contains($0.name) }
            .count
        // A heading swallowed by the block above it is the quiet failure this catches: the document
        // still renders, and one section's title is simply part of the paragraph before it.
        #expect(
            rendered == expected,
            "\(name): \(rendered) headings rendered, \(expected) in source"
        )
    }

    /// Slice 2's exit criterion, over the real document rather than a fixture: PLAN.md is 60-odd
    /// headings deep, carries duplicate titles across milestones, and is full of the punctuation and
    /// em dashes the slug rule drops — so a TOC over it exercises the numbering, not just the shape.
    @Test("a TOC over PLAN.md links only to anchors the same render emitted")
    func tableOfContentsResolves() throws {
        let html = MarkdownDocument.render("[[_TOC_]]\n\n" + (try source("PLAN.md"))).html
        let tags = Self.tags(in: html)
        let ids = Set(tags.compactMap { $0.attributes["id"] })
        let fragments = tags.compactMap { $0.attributes["href"] }
            .filter { $0.hasPrefix("#") }
            .map { String($0.dropFirst()) }
        #expect(fragments.count > 10)
        // Every anchor is linked and every link is an anchor. PLAN.md carries no in-page links of
        // its own (checked: the whole corpus has none), so the two sets are the TOC and the
        // headings — and comparing counts as well as membership is what catches a *dropped* entry,
        // which set membership alone would call a pass.
        #expect(fragments.count == ids.count)
        for fragment in fragments {
            #expect(
                ids.contains(fragment),
                "PLAN.md: the TOC links to #\(fragment), which is not an id"
            )
        }
        // And the outline is nested, not flat — a `<nav>` of one long list would satisfy every
        // assertion above while saying nothing about the document's shape.
        #expect(html.contains("<nav class=\"toc\">"))
        let nav = try #require(html.range(of: "</nav>")).lowerBound
        #expect(html[..<nav].components(separatedBy: "<ul>").count > 2)
    }

    /// The other half of Slice 2's exit: a fence in the rendered page is coloured by the **same**
    /// scanner as the file in source mode.
    ///
    /// README.md is the corpus document that carries a tagged fence — two ```` ```bash ```` blocks,
    /// which is worth naming because PLAN.md's four fences carry no info string at all and would
    /// have made this assertion unfailable (the trap the suite's own `notesStructure` comment
    /// already records once).
    @Test("README's bash fences are coloured by M17's scanner, token for token")
    func fencesAreHighlighted() throws {
        let source = try source("README.md")
        let html = MarkdownDocument.render(source).html
        // Asserted against `SyntaxHighlighter`'s own answer rather than a golden string, so the two
        // cannot drift apart without this failing — and taken from the file's real fence body, so
        // the claim is about this document rather than about a sample invented to pass.
        let body = try #require(Self.firstFenceBody(in: source, info: "bash"))
        let comments = SyntaxHighlighter.tokens(in: body, language: .shell)
            .filter { $0.kind == .comment }
        #expect(!comments.isEmpty)
        for comment in comments {
            let text = String(
                decoding: Array(body.utf16)[comment.offset..<comment.end],
                as: UTF16.self
            )
            #expect(html.contains("<span class=\"tok-comment\">\(text)</span>"))
        }
    }

    /// The body of the first fence carrying `info`, taken from the source by hand — the parser is
    /// what is under test, so it cannot also be the thing that says what the fence contained.
    private static func firstFenceBody(in text: String, info: String) -> String? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let open = lines.firstIndex(where: { $0 == "```" + info }) else { return nil }
        let rest = lines[lines.index(after: open)...]
        guard let close = rest.firstIndex(where: { $0.hasPrefix("```") }) else { return nil }
        return rest[..<close].joined(separator: "\n") + "\n"
    }

    @Test("NOTES.md keeps its deep nesting, its tables, and its punctuation inside code")
    func notesStructure() throws {
        let html = MarkdownDocument.render(try source("docs/NOTES.md")).html
        // Deep nesting is what this file actually has, and a parser that loses the content column
        // collapses every level of it into one.
        #expect(Self.tags(in: html).filter { $0.name == "ul" && !$0.isClosing }.count > 50)
        #expect(html.contains("<table>"))
        // Inline code holding Markdown punctuation. NOTES.md's own entry on this is the reason it
        // is worth pinning: `*.jpg;*.png` is a valid emphasis pair, and a renderer that reads the
        // asterisks eats the two wildcards out of a sentence explaining wildcards.
        #expect(html.contains("<code>*.jpg;*.png</code>"))
        // No fenced code in this file at all — so the fence assertion lives with PLAN.md, which
        // has two. Worth stating rather than deleting: an assertion that cannot fail is worse than
        // none, and this one silently could not until it was moved.
        #expect(MarkdownDocument.render(try source("PLAN.md")).html.contains("<pre><code"))
    }

    // MARK: - Helpers

    private struct Tag {
        let name: String
        let isClosing: Bool
        let attributes: [String: String]
    }

    /// Every tag in a fragment, with the names of its attributes. Deliberately naive — the input is
    /// our own output, so no attribute value carries a `<` or a `>` to trip it: escaping guarantees
    /// that, which is exactly why *this* scan is allowed to be simple and the renderer is not.
    private static func tags(in html: String) -> [Tag] {
        var tags: [Tag] = []
        var characters = Substring(html)
        while let open = characters.firstIndex(of: "<") {
            characters = characters[characters.index(after: open)...]
            let isClosing = characters.first == "/"
            if isClosing { characters = characters.dropFirst() }
            let name = characters.prefix { $0.isLetter || $0.isNumber }
            guard !name.isEmpty else { continue }
            characters = characters[name.endIndex...]
            let close = characters.firstIndex(of: ">") ?? characters.endIndex
            tags.append(Tag(
                name: String(name).lowercased(),
                isClosing: isClosing,
                attributes: attributes(in: characters[..<close])
            ))
            characters = characters[close...]
        }
        return tags
    }

    /// The attributes inside one tag, valued or bare (`disabled`, which maps to an empty value).
    private static func attributes(in tag: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        var rest = tag
        while !rest.isEmpty {
            rest = rest.drop(while: \.isWhitespace)
            let name = rest.prefix { $0.isLetter || $0 == "-" }
            guard !name.isEmpty else { break }
            rest = rest[name.endIndex...]
            guard rest.first == "=", rest.dropFirst().first == "\"" else {
                attributes[String(name).lowercased()] = ""
                continue
            }
            rest = rest.dropFirst(2)
            let value = rest.prefix { $0 != "\"" }
            attributes[String(name).lowercased()] = String(value)
            rest = rest[value.endIndex...].dropFirst()
        }
        return attributes
    }

    /// ATX headings in the source, counted independently of the parser under test — a fence-aware
    /// scan of four lines' worth of rules, so the two answers are arrived at separately.
    private static func atxHeadingCount(in text: String) -> Int {
        var count = 0
        var fence: Character?
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let content = line.drop { $0 == " " }
            if let marker = content.first, marker == "`" || marker == "~",
               content.prefix { $0 == marker }.count >= 3 {
                fence = fence == marker ? nil : (fence ?? marker)
                continue
            }
            guard fence == nil, line.first == "#" else { continue }
            let hashes = content.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), content.dropFirst(hashes).first == " " { count += 1 }
        }
        return count
    }
}
