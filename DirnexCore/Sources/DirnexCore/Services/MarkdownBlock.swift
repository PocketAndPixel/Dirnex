import Foundation

/// One block-level element of a Markdown document (PLAN.md §M18 ▸ Slice 1).
///
/// The block pass decides *what each region of the file is*; the inline pass then reads the text
/// inside one. That is why every case here carries its text as **unparsed inline source** rather
/// than as inline nodes: a heading, a paragraph and a table cell are the same problem once the block
/// pass has found them, so there is one inline parser called from one place rather than a call at
/// each site that happens to hold text.
///
/// Two passes rather than the single one `SyntaxMarkdownScanner` makes over the same syntax, and the
/// difference is deliberate (PLAN.md §M18). That scanner only ever *adds colour*, so it can afford
/// one lookahead and a construct it misreads costs a wrong colour. This produces the document, so it
/// gets the previous line and the whole of a block — which is exactly what **setext headings** and
/// **indented code blocks** need, the two constructs M17 named as out of its reach.
public enum MarkdownBlock: Equatable, Sendable {
    /// `# Heading` or its setext form. `level` is 1…6.
    case heading(level: Int, text: String)
    case paragraph(String)
    case thematicBreak
    /// A fenced or indented code block. `info` is the fence's info string — the language name Slice
    /// 2 colours the body with — and is `nil` for an indented block, which has nowhere to carry one.
    case codeBlock(info: String?, code: String)
    case blockQuote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    /// YAML front matter, recognized rather than ignored: an opening `---` otherwise parses as a
    /// thematic break and the document opens looking broken. A file manager shows what is in the
    /// file, so it renders — as a subdued table, not as prose.
    case frontMatter([MarkdownFrontMatterEntry])
    /// A `[[_TOC_]]` marker, standing in for the outline the renderer builds from the document's
    /// headings. A **block**, decided in the block pass, which is what keeps the same marker inside
    /// a code fence the literal text it is there to be (PLAN.md §M18 ▸ Slice 2).
    case tableOfContents
}

/// A bullet or numbered list, and whether its items are paragraphs or bare text.
public struct MarkdownList: Equatable, Sendable {
    public let isOrdered: Bool
    /// The first number of an ordered list, which is not always 1 — a list resuming after a code
    /// sample starts where its author says it does.
    public let start: Int
    /// Whether the items are drawn tight (bare text) or loose (each in its own paragraph).
    /// CommonMark's rule: a list is loose when a blank line separates any two of its items, or
    /// separates two blocks inside one. It is a property of the *list*, not of the item, which is
    /// why one blank line changes the spacing of every item at once.
    public let isTight: Bool
    public let items: [MarkdownListItem]

    public init(isOrdered: Bool, start: Int, isTight: Bool, items: [MarkdownListItem]) {
        self.isOrdered = isOrdered
        self.start = start
        self.isTight = isTight
        self.items = items
    }
}

public struct MarkdownListItem: Equatable, Sendable {
    /// A GFM task item's checkbox, or `nil` for an ordinary item.
    public let task: MarkdownTaskState?
    /// The item's own content, parsed as blocks — which is what makes a list nest, holds a code
    /// sample inside a step, and lets an item carry two paragraphs.
    public let blocks: [MarkdownBlock]

    public init(task: MarkdownTaskState? = nil, blocks: [MarkdownBlock]) {
        self.task = task
        self.blocks = blocks
    }
}

public enum MarkdownTaskState: Equatable, Sendable {
    case unchecked
    case checked
}

/// A GFM table: a header row, a per-column alignment taken from the delimiter row, and the body.
///
/// Every cell is unparsed inline source, like every other text in this model. The row arrays are
/// **not** promised to match `alignments` in length — a real document has ragged rows, and the
/// renderer pads or drops rather than the parser refusing the table.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: String, Equatable, Sendable {
        case none
        case left
        case center
        case right
    }

    public let header: [String]
    public let alignments: [Alignment]
    public let rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

/// One `key: value` line of YAML front matter.
///
/// Deliberately not a YAML parser: front matter is read for *display*, so a nested structure is
/// shown as the text it is written as rather than being modelled. Anything that is not a `key:
/// value` line at the top level keeps its whole line as the value under an empty key, which renders
/// as an unlabelled row instead of disappearing.
public struct MarkdownFrontMatterEntry: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
