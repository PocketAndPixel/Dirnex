import Foundation

/// Blocks to HTML (PLAN.md §M18 ▸ Slice 1). The inline half is in `MarkdownHTMLRenderer+Inline`.
///
/// The output is a **fragment**, not a document: no `<html>`, no `<head>`, no `<style>`. The
/// stylesheet is the app's, because the app is the only side that knows which appearance is on
/// screen and what `SyntaxTheme` resolves to in it — the same division M17 draws between what a
/// span *is* and what colour it takes. A core that emitted colours would be a core that could not
/// follow a user switching to dark mode.
///
/// Class names, likewise, are the whole of this side's vocabulary. Every one of them is a *kind*,
/// never an appearance.
enum MarkdownHTMLRenderer {
    static func render(_ scan: MarkdownBlockScan, options: MarkdownRenderOptions) -> String {
        let context = Context(scan: scan, options: options)
        return scan.blocks.map { context.render($0) }.joined(separator: "\n")
    }

    /// What every block needs while rendering: the link definitions to resolve against, the
    /// document's headings, and the caller's say over where an image's bytes come from.
    ///
    /// A **class**, not a struct, for one reason: the anchors are handed out in document order, so
    /// rendering a heading advances a cursor. A struct would need every `render` on the walk to be
    /// `mutating`, which recursion through `map` cannot express.
    final class Context {
        let references: [String: MarkdownLinkReference]
        let options: MarkdownRenderOptions
        let headings: [MarkdownHeading]
        /// How many headings have been rendered. See `nextHeadingID`.
        private var headingIndex = 0

        init(scan: MarkdownBlockScan, options: MarkdownRenderOptions) {
            references = scan.references
            headings = scan.headings
            self.options = options
        }

        func render(_ block: MarkdownBlock) -> String {
            switch block {
            case let .heading(level, text):
                heading(level: level, text: text)
            case let .paragraph(text):
                MarkdownHTML.element("p", inline(text))
            case .thematicBreak:
                "<hr>"
            case let .codeBlock(info, code):
                codeBlock(info: info, code: code)
            case let .blockQuote(blocks):
                MarkdownHTML.element("blockquote", render(blocks))
            case let .list(list):
                self.list(list)
            case let .table(table):
                self.table(table)
            case let .frontMatter(entries):
                frontMatter(entries)
            case .tableOfContents:
                MarkdownTOC.nav(for: headings)
            }
        }

        func render(_ blocks: [MarkdownBlock]) -> String {
            blocks.map(render).joined(separator: "\n")
        }

        // MARK: Leaf blocks

        /// A heading, carrying the anchor every link in the document resolves against — including
        /// the ones the file's own author wrote by hand, which is why the slug follows GitHub's
        /// rule to the letter (`MarkdownSlug`).
        private func heading(level: Int, text: String) -> String {
            MarkdownHTML.element(
                "h\(level)",
                inline(text),
                attributes: MarkdownHTML.attribute("id", nextHeadingID())
            )
        }

        /// The next anchor from the list the parse produced.
        ///
        /// By **position**, because that list was gathered in exactly this order — one traversal,
        /// one slugger, so a TOC entry and the heading it points at can never disagree. `nil` past
        /// the end leaves the heading without an `id` rather than inventing one, which would be a
        /// second spelling of the rule and the thing this design exists to avoid.
        private func nextHeadingID() -> String? {
            guard headingIndex < headings.count else { return nil }
            defer { headingIndex += 1 }
            return headings[headingIndex].slug
        }

        /// A fenced block keeps its info string as a class, in the `language-…` spelling every
        /// other tool uses, and its body is coloured by M17's own scanner
        /// (`MarkdownCodeHighlighting`) when that info names a language.
        private func codeBlock(info: String?, code: String) -> String {
            // The first word only: an info string may carry more (`swift showLineNumbers`), and the
            // language is the part that names a grammar.
            let language = info?.split(whereSeparator: \.isWhitespace).first.map(String.init)
            let attributes = language.map { " class=\"language-\(MarkdownHTML.escaped($0))\"" } ?? ""
            return "<pre>" + MarkdownHTML.element(
                "code",
                MarkdownCodeHighlighting.body(code, info: info),
                attributes: attributes
            ) + "</pre>"
        }

        private func list(_ list: MarkdownList) -> String {
            let tag = list.isOrdered ? "ol" : "ul"
            // `start` only when it is not 1, so the common case emits no attribute at all.
            var attributes = list.isOrdered && list.start != 1 ? " start=\"\(list.start)\"" : ""
            if list.items.contains(where: { $0.task != nil }) { attributes += " class=\"task-list\"" }
            let items = list.items.map { item(from: $0, tight: list.isTight) }
            return MarkdownHTML.element(
                tag,
                "\n" + items.joined(separator: "\n") + "\n",
                attributes: attributes
            )
        }

        /// One item. A **tight** list unwraps a lone paragraph — which is what makes it tight, and
        /// is a structural decision rather than a stylistic one: the `<p>` is what a stylesheet
        /// would have to fight, and it cannot win against a browser's own margins reliably.
        private func item(from item: MarkdownListItem, tight: Bool) -> String {
            var inner = tight ? unwrappedParagraph(item.blocks) : render(item.blocks)
            var attributes = ""
            if let task = item.task {
                let checked = task == .checked ? " checked" : ""
                // `disabled`, because a preview shows the file rather than editing it — an
                // interactive box would offer a change it has nowhere to write (§M11).
                inner = "<input type=\"checkbox\" disabled\(checked)> " + inner
                attributes = " class=\"task\""
            }
            return MarkdownHTML.element("li", inner, attributes: attributes)
        }

        private func unwrappedParagraph(_ blocks: [MarkdownBlock]) -> String {
            guard case let .paragraph(text)? = blocks.first else { return render(blocks) }
            let rest = Array(blocks.dropFirst())
            let tail = rest.isEmpty ? "" : "\n" + render(rest)
            return inline(text) + tail
        }

        private func table(_ table: MarkdownTable) -> String {
            let head = row(table.header, cell: "th", alignments: table.alignments)
            let body = table.rows
                .map { row($0, cell: "td", alignments: table.alignments) }
                .joined(separator: "\n")
            let sections = MarkdownHTML.element("thead", "\n\(head)\n")
                + (body.isEmpty ? "" : "\n" + MarkdownHTML.element("tbody", "\n\(body)\n"))
            return MarkdownHTML.element("table", "\n\(sections)\n")
        }

        /// One row, padded or truncated to the header's width. A ragged row is ordinary in a real
        /// document — a trailing `|` forgotten, a column added to the header and not below it — and
        /// dropping the whole table over one would lose far more than it protects.
        private func row(_ cells: [String], cell: String, alignments: [MarkdownTable.Alignment]) -> String {
            let rendered = alignments.indices.map { column -> String in
                let text = column < cells.count ? cells[column] : ""
                return MarkdownHTML.element(
                    cell,
                    inline(text),
                    attributes: alignmentAttribute(alignments[column])
                )
            }
            return MarkdownHTML.element("tr", rendered.joined())
        }

        /// A class, not an inline `style`: the alignment is a fact about the column, and how it is
        /// drawn stays with the rest of the appearance in the app's stylesheet.
        private func alignmentAttribute(_ alignment: MarkdownTable.Alignment) -> String {
            alignment == .none ? "" : " class=\"align-\(alignment.rawValue)\""
        }

        /// Front matter as a two-column table. A row with no key spans both columns, which is what
        /// a nested value or a list entry becomes — visible, and visibly a continuation.
        private func frontMatter(_ entries: [MarkdownFrontMatterEntry]) -> String {
            let rows = entries.map { entry -> String in
                guard !entry.key.isEmpty else {
                    return MarkdownHTML.element(
                        "tr",
                        MarkdownHTML.element("td", inline(entry.value), attributes: " colspan=\"2\"")
                    )
                }
                return MarkdownHTML.element(
                    "tr",
                    MarkdownHTML.element("th", MarkdownHTML.escaped(entry.key))
                        + MarkdownHTML.element("td", inline(entry.value))
                )
            }
            return MarkdownHTML.element(
                "table",
                "\n" + rows.joined(separator: "\n") + "\n",
                attributes: " class=\"front-matter\""
            )
        }
    }
}
