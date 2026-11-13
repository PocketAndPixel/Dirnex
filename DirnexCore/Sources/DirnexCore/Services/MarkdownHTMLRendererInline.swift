import Foundation

/// The inline half of the renderer (PLAN.md §M18 ▸ Slice 1).
///
/// A separate file rather than a second half of `MarkdownHTMLRenderer`, which sits near SwiftLint's
/// `type_body_length` the way the AppKit controllers do (docs/NOTES.md ▸ lint ceilings). Swift's
/// `private` does not cross files, so what these two share is `internal`.
extension MarkdownHTMLRenderer.Context {
    /// Parse and render one block's text in a single call — the only entry the block side uses, so
    /// there is one place that decides an inline pass happens and one place it can be skipped from.
    func inline(_ source: String) -> String {
        render(MarkdownInlineParser.parse(source, references: references, footnotes: footnoteKeys))
    }

    /// The nodes in order, with each **run of text** drawn as one: the text and soft breaks between
    /// two elements, which is what an HTML text node holds and what GitHub reads emoji shortcodes
    /// across (`MarkdownEmoji`). The bytes are the same as drawing the nodes one by one, since a
    /// soft break draws as the newline it is joined with.
    func render(_ nodes: [MarkdownInline]) -> String {
        var html = ""
        var run = ""
        for node in nodes {
            switch node {
            case let .text(text):
                run += text
            case .softBreak:
                run += "\n"
            default:
                if !run.isEmpty {
                    html += MarkdownHTML.escaped(MarkdownEmoji.converting(run))
                    run = ""
                }
                html += render(node)
            }
        }
        if !run.isEmpty { html += MarkdownHTML.escaped(MarkdownEmoji.converting(run)) }
        return html
    }

    func render(_ node: MarkdownInline) -> String {
        switch node {
        case let .text(text):
            MarkdownHTML.escaped(text)
        case let .code(code):
            MarkdownHTML.element("code", MarkdownHTML.escaped(code))
        case let .emphasis(children):
            MarkdownHTML.element("em", render(children))
        case let .strong(children):
            MarkdownHTML.element("strong", render(children))
        case let .strikethrough(children):
            MarkdownHTML.element("del", render(children))
        case let .link(destination, title, children):
            link(destination: destination, title: title, children: children)
        case let .image(source, title, alt):
            image(source: source, title: title, alt: alt)
        case let .footnoteReference(key):
            footnoteReference(key)
        case .lineBreak:
            "<br>\n"
        case .softBreak:
            "\n"
        }
    }

    /// A link whose destination this build will not point at keeps its **text** and loses its
    /// `href` — the words the author wrote are still what the reader sees, and nothing clickable
    /// is left behind (`MarkdownURL`).
    private func link(destination: String, title: String?, children: [MarkdownInline]) -> String {
        let inner = render(children)
        guard let href = MarkdownURL.sanitized(destination, isImage: false) else { return inner }
        return MarkdownHTML.element(
            "a",
            inner,
            attributes: MarkdownHTML.attribute("href", href) + MarkdownHTML.attribute("title", title)
        )
    }

    /// An image, with its source passed through the caller's resolver first.
    ///
    /// The resolver is the seam PLAN.md §M18's first probe lands in: whether a generated document
    /// reaches its sibling files through a base URL, a scoped file load or a `data:` URI is a
    /// **WebKit** question, and the answer belongs to the app that owns the web view. The core's
    /// default is identity — the source exactly as the file wrote it — so the parser's tests never
    /// depend on how that question came out. (It came out `data:`, because a generated page has no
    /// file access at all; the app reads the bytes and hands them back here.)
    ///
    /// Sanitized **after** resolving, not before: the resolver's answer is what reaches the `src`
    /// attribute, so it is the string the scheme allow-list has to be asked about.
    ///
    /// A refused source renders as its **alt text**, not as a broken-image icon: the alt is what
    /// the author wrote to describe the picture, and it is more use than a gray box.
    private func image(source: String, title: String?, alt: String) -> String {
        let resolved = options.resolveImageSource(source)
        guard let src = MarkdownURL.sanitized(resolved, isImage: true) else {
            return MarkdownHTML.escaped(alt)
        }
        return "<img" + MarkdownHTML.attribute("src", src)
            + MarkdownHTML.attribute("alt", alt)
            + MarkdownHTML.attribute("title", title) + ">"
    }
}
