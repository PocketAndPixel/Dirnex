import Foundation

/// Footnotes: each reference's number, and the list at the foot of the page (PLAN.md §M39 ▸ Slice 6).
///
/// The markup is GitHub's with its `user-content-` prefix and `data-` attributes left off, which are
/// GitHub's script's business: `<sup><a href="#fn-1" id="fnref-1">1</a></sup>` for a reference, and
/// a `<section class="footnotes">` holding an `<ol>` whose items carry `id="fn-1"` and a `↩` back to
/// every reference, the second and later ones numbered (`↩²`). The links are ordinary in-page anchors,
/// which the preview already scrolls to.
extension MarkdownHTMLRenderer.Context {
    /// A reference, numbered by the order its footnote was first referenced in.
    func footnoteReference(_ key: String) -> String {
        guard let footnote = footnotes[key] else { return "" }
        let count = (footnoteReferences[key] ?? 0) + 1
        footnoteReferences[key] = count
        if count == 1 { footnoteOrder.append(key) }
        let number = (footnoteOrder.firstIndex(of: key) ?? footnoteOrder.count) + 1
        let anchor = MarkdownFootnotes.anchor(for: footnote.label)
        let link = MarkdownHTML.element(
            "a",
            String(number),
            attributes: MarkdownHTML.attribute("href", "#fn-" + anchor)
                + MarkdownHTML.attribute("id", Self.referenceID(anchor: anchor, count: count))
                + " class=\"footnote-ref\""
        )
        return MarkdownHTML.element("sup", link)
    }

    /// Every footnote the page referenced, or nothing when it referenced none.
    ///
    /// Two steps, because a footnote can reference another: each body is drawn first, which may number
    /// a footnote no paragraph above named, and only once every body is drawn is it known how many
    /// references each footnote has to point back to.
    func footnoteSection() -> String {
        var bodies: [DrawnFootnote] = []
        var position = 0
        while position < footnoteOrder.count {
            let key = footnoteOrder[position]
            position += 1
            guard let footnote = footnotes[key] else { continue }
            var blocks = footnote.blocks
            var lastParagraph: String?
            if case let .paragraph(text)? = blocks.last {
                blocks.removeLast()
                lastParagraph = inline(text)
            }
            bodies.append(
                DrawnFootnote(key: key, leading: render(blocks), lastParagraph: lastParagraph)
            )
        }
        guard !bodies.isEmpty else { return "" }
        let items = bodies.map { body -> String in
            let anchor = footnotes[body.key].map { MarkdownFootnotes.anchor(for: $0.label) } ?? ""
            let backReferences = backReferences(
                anchor: anchor,
                count: footnoteReferences[body.key] ?? 1
            )
            // The way back goes at the end of the last paragraph, as GitHub puts it, and on a line of
            // its own when the footnote ends in anything else.
            let tail = body.lastParagraph.map {
                MarkdownHTML.element("p", $0.isEmpty ? backReferences : $0 + " " + backReferences)
            } ?? backReferences
            let parts = [body.leading, tail].filter { !$0.isEmpty }
            return MarkdownHTML.element(
                "li",
                "\n" + parts.joined(separator: "\n") + "\n",
                attributes: MarkdownHTML.attribute("id", "fn-" + anchor)
            )
        }
        let list = MarkdownHTML.element("ol", "\n" + items.joined(separator: "\n") + "\n")
        return MarkdownHTML.element(
            "section",
            "\n" + list + "\n",
            attributes: " class=\"footnotes\""
        )
    }

    /// One footnote's body, drawn before the ways back to its references are known: every block but
    /// a last paragraph, and that paragraph's inline text, which the ways back are written into.
    private struct DrawnFootnote {
        let key: String
        let leading: String
        let lastParagraph: String?
    }

    /// `↩` back to each reference, the second and later ones numbered.
    private func backReferences(anchor: String, count: Int) -> String {
        (1...max(count, 1)).map { index -> String in
            let mark = index == 1 ? "↩" : "↩" + MarkdownHTML.element("sup", String(index))
            return MarkdownHTML.element(
                "a",
                mark,
                attributes: MarkdownHTML.attribute(
                    "href",
                    "#" + Self.referenceID(anchor: anchor, count: index)
                ) + " class=\"footnote-backref\""
            )
        }.joined(separator: " ")
    }

    /// `fnref-1` for a footnote's first reference, `fnref-1-2` for its second, as GitHub names them.
    private static func referenceID(anchor: String, count: Int) -> String {
        count == 1 ? "fnref-" + anchor : "fnref-\(anchor)-\(count)"
    }
}
