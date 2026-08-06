import Foundation

/// One inline element inside a block (PLAN.md §M18 ▸ Slice 1).
///
/// `indirect` because emphasis nests: `**bold with _italic_ inside**` is a `strong` holding an
/// `emphasis`, and a link's text is a list of these in its own right.
public indirect enum MarkdownInline: Equatable, Sendable {
    /// Literal text, still holding whatever characters the file did. Escaping happens on the way
    /// **out**, in the renderer, not here — the parser's job is to say what the author wrote, and a
    /// node that escaped its own text could not be compared against the source in a test.
    case text(String)
    /// A code span. Its content is literal by definition: no inline construct inside one is read,
    /// which is the whole reason a fence is how this document quotes Markdown at itself.
    case code(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case link(destination: String, title: String?, children: [MarkdownInline])
    /// An image. Its alt text stays a plain `String` rather than nodes: it lands in an attribute,
    /// where markup cannot be drawn, so parsing it would produce nodes with nowhere to go.
    case image(source: String, title: String?, alt: String)
    /// A newline the author asked to keep — two trailing spaces, or a trailing backslash.
    case lineBreak
    /// A newline inside a paragraph, which renders as an ordinary space. Kept as a node rather than
    /// folded into `.text` so a renderer can decide: this is where a CJK document, or a preview that
    /// wanted one sentence per line, would differ.
    case softBreak
}

/// A `[label]: destination "title"` definition, collected before the block pass so a reference link
/// can resolve against one written *after* it — which is the common shape, with every definition at
/// the foot of the file.
public struct MarkdownLinkReference: Equatable, Sendable {
    public let destination: String
    public let title: String?

    public init(destination: String, title: String? = nil) {
        self.destination = destination
        self.title = title
    }

    /// The key a label matches under. CommonMark folds case and collapses internal whitespace, so
    /// `[Read More]` finds `[read   more]:` — worth having, because a definition and its use are
    /// usually hundreds of lines apart and nothing warns when they disagree.
    public static func key(for label: String) -> String {
        label
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}
