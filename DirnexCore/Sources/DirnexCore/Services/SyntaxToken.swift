import Foundation

/// One coloured span in a previewed text file (PLAN.md §M17).
///
/// Offsets are plain `Int` counts of **UTF-16 code units**, which is what an `NSRange` indexes. The
/// core imports no AppKit and never sees an `NSAttributedString`, but handing back offsets in any
/// other unit would make the app re-walk the whole string to convert them — so the one
/// AppKit-shaped decision the core does make is the unit its offsets are measured in.
public struct SyntaxToken: Equatable, Sendable {
    /// What a span *is*, semantically. Six kinds and no more, which is the milestone's one open
    /// question closed at open (PLAN.md §7): a small vocabulary maps onto system dynamic colours,
    /// which resolve in both appearances for free, and keeps the whole feature out of Settings.
    ///
    /// The scanner never emits `.plain` — an unclaimed run of text already renders in the text
    /// view's own `.textColor`, so a token for it would be a span that changes nothing. It exists
    /// because the *theme* needs a name for that colour.
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// A reserved word, a preprocessor directive, an annotation — the language's own vocabulary.
        case keyword
        /// A string or character literal, delimiters included.
        case string
        /// A comment, in either form, delimiters included.
        case comment
        /// A numeric literal.
        case number
        /// A built-in type name, or a markup tag. One kind because they are the same thing to a
        /// reader: the name of the shape a value or an element has.
        case typeOrTag
        /// A line a diff adds, and a line it removes.
        ///
        /// The two kinds PLAN.md's "six and no more" grew by, added with Slice 2's diff scanner and
        /// **not** a reopening of the question §7 closed — that question was how much of a theme the
        /// *user* owns, and the answer is unchanged: system dynamic colours, no Settings surface.
        /// These are two more entries in the same dictionary.
        ///
        /// The alternative was to borrow — colour an added line `.comment` and a removed one
        /// `.string`, which renders correctly against the colours Slice 3 is likely to pick. It is
        /// rejected because it **couples** the diff to a decision made about something else: the day
        /// `.comment` becomes grey, as many themes have it, a diff silently loses its green and
        /// nothing in the code says why.
        case inserted
        case deleted
        /// Everything else. Never emitted; see the note above.
        case plain
    }

    /// Offset of the span's first UTF-16 code unit from the start of the text.
    public let offset: Int
    /// The span's length in UTF-16 code units. Always positive — a zero-length token is not emitted.
    public let length: Int
    public let kind: Kind

    public init(offset: Int, length: Int, kind: Kind) {
        self.offset = offset
        self.length = length
        self.kind = kind
    }

    /// One past the span's last code unit.
    public var end: Int { offset + length }
}
