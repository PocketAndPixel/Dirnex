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
    /// `[^label]`, a reference to a footnote the document defines. It carries the definition's key
    /// (`MarkdownLinkReference.key(for:)`); the number it draws as depends on the references before
    /// it, so the renderer hands it out (`MarkdownFootnotes`).
    case footnoteReference(String)
    /// `$x$`, `$$x$$` or `` $`x`$ ``: TeX, exactly as written between its delimiters
    /// (`MarkdownMath`). `written` is the whole span, delimiters included, which is what draws when
    /// the TeX cannot be (`TeXMath`).
    case math(tex: String, display: Bool, written: String)
    /// A newline the author asked to keep — two trailing spaces, or a trailing backslash.
    case lineBreak
    /// A newline inside a paragraph, which renders as an ordinary space. Kept as a node rather than
    /// folded into `.text` so a renderer can decide: this is where a CJK document, or a preview that
    /// wanted one sentence per line, would differ.
    case softBreak
}

extension MarkdownInline {
    /// The literal text of `nodes` — every construct flattened away, which is what an image's `alt`
    /// and a heading's anchor need. A fact about the nodes rather than about reading them, which is
    /// why it lives here and not in `MarkdownInlineParser` (moved 2026-11-14, when that type reached
    /// SwiftLint's `type_body_length`).
    static func plainText(_ nodes: [MarkdownInline]) -> String {
        nodes.map { node in
            switch node {
            case let .text(text): text
            case let .code(code): code
            case let .emphasis(children), let .strong(children), let .strikethrough(children):
                plainText(children)
            case let .link(_, _, children): plainText(children)
            case let .image(_, _, alt): alt
            // Its number is the renderer's to hand out, so it adds nothing to a heading's anchor
            // (`MarkdownFootnotes` names the one way that departs from GitHub).
            case .footnoteReference: ""
            // The TeX, as GitHub's anchor reads the text of its math element: `## The $x^2$ term`
            // anchors as `#the-x2-term` either way.
            case let .math(tex, _, _): tex
            case .lineBreak, .softBreak: " "
            }
        }.joined()
    }
}

extension MarkdownInline {
    /// A code span's content: line breaks become spaces, and one space comes off each end when both
    /// have one, the rule that lets `` ` `` be written as `` `` ` `` ``. `` $`…`$ `` trims the same
    /// way (`MarkdownMath`).
    static func codeSpanContent(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > 2, text.hasPrefix(" "), text.hasSuffix(" "),
           text.contains(where: { $0 != " " }) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// How many times `character` repeats from `start`: a backtick fence's length, an emphasis
    /// run's, a dollar run's.
    static func runLength(of character: Character, in characters: [Character], from start: Int) -> Int {
        var length = 0
        while start + length < characters.count, characters[start + length] == character {
            length += 1
        }
        return length
    }
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
