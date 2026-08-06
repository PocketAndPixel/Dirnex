import Foundation

/// `[[_TOC_]]`, as a nested `<nav>` (PLAN.md §M18 ▸ Slice 2).
///
/// The outline is rebuilt from heading *levels*, which do not have to be well-formed: a file may
/// open at `##`, skip from `#` to `###`, or go back up. So the nesting is driven by a stack rather
/// than by arithmetic on the level — a document that jumps two levels gets one level of nesting,
/// which is what every outline view does and what the author plainly meant.
///
/// The entry's text is the heading's **plain text**, not its markup, and that is a correctness rule
/// rather than a simplification: a heading containing a link would otherwise nest an `<a>` inside
/// the entry's own `<a>`, which no browser renders as anything sensible.
enum MarkdownTOC {
    static func nav(for headings: [MarkdownHeading]) -> String {
        // A heading with no anchor has nothing to link with, so it is not an entry. An empty
        // document, or one whose headings are all unsluggable, gets no `<nav>` at all rather than an
        // empty one — a marker that renders as nothing says "there are no headings" more clearly
        // than an empty box does.
        let entries = headings.filter { !$0.slug.isEmpty }
        guard !entries.isEmpty else { return "" }
        var builder = Builder()
        for heading in entries { builder.add(heading) }
        return MarkdownHTML.element(
            "nav",
            "\n" + builder.close() + "\n",
            attributes: " class=\"toc\""
        )
    }

    /// The nesting, as an explicit stack of the `<ul>` levels currently open.
    ///
    /// An `<li>` is open exactly while `open` is non-empty, which is what lets a deeper heading nest
    /// its list *inside* the item above it — the shape a browser needs, and the one a naive
    /// "close the item, then open a list" ordering gets wrong.
    private struct Builder {
        private var html = ""
        private var open: [Int] = []

        mutating func add(_ heading: MarkdownHeading) {
            if open.isEmpty {
                html += "<ul>\n"
                open.append(heading.level)
            } else if heading.level > open[open.count - 1] {
                html += "\n<ul>\n"
                open.append(heading.level)
            } else {
                html += "</li>\n"
                while open.count > 1, heading.level < open[open.count - 1] {
                    html += "</ul>\n</li>\n"
                    open.removeLast()
                }
                // Still shallower than the only list open: the document went *up* past where it
                // started, so the outermost list takes the new level and everything below it nests
                // against that instead.
                if heading.level < open[open.count - 1] { open[open.count - 1] = heading.level }
            }
            html += "<li>" + item(heading)
        }

        mutating func close() -> String {
            guard !open.isEmpty else { return html }
            html += "</li>\n"
            while open.count > 1 {
                html += "</ul>\n</li>\n"
                open.removeLast()
            }
            return html + "</ul>"
        }

        private func item(_ heading: MarkdownHeading) -> String {
            MarkdownHTML.element(
                "a",
                MarkdownHTML.escaped(heading.text),
                attributes: MarkdownHTML.attribute("href", "#" + heading.slug)
            )
        }
    }
}
