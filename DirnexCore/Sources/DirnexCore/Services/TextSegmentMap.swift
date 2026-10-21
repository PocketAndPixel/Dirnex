import Foundation

/// Where a range in several texts joined together lies: which texts, and where in each
/// (2026-09-17).
///
/// Finding in a Quick View preview reads one text and answers UTF-16 offsets into it
/// (``TextFindMatches``), and two of the surfaces that find are not one text at all. A PDF is its
/// pages, and `PDFDocument.string` is exactly those pages joined by a single `\n` — measured on
/// documents of 1, 78 and 231 pages, where the join reproduced the whole string byte for byte. A
/// converted workbook is its main page plus the frame its visible sheet is drawn in. Both are
/// searched as one text and then addressed a piece at a time: a match has to become a
/// `PDFSelection` on *its* page, or a `Range` in *its* frame.
///
/// So the join is here rather than in either surface, with the arithmetic in one place and tested
/// once. Lengths are UTF-16 units, which is what `TextFindMatches` counts and what both
/// `PDFPage.selection(for:)` and a DOM text node's offsets are spent in.
public struct TextSegmentMap: Sendable, Equatable {
    /// Each segment's length in UTF-16 units, in the order they were joined.
    public let lengths: [Int]
    /// The separator's length in UTF-16 units — 1 for the `\n` between PDF pages.
    public let separator: Int

    public init(lengths: [Int], separator: Int = 1) {
        self.lengths = lengths
        self.separator = max(0, separator)
    }

    /// `range` cut into the pieces each segment holds, in order, with each piece's offsets relative
    /// to its own segment.
    ///
    /// A range that stays inside one segment — which nearly every match does — gives one piece. One
    /// that runs across a page break gives a piece per page and drops the separator between them,
    /// so a match spanning two pages highlights on both and covers no character that is not there.
    /// Empty for a range that lies entirely in separators or past the end.
    public func split(_ range: Range<Int>) -> [(index: Int, range: Range<Int>)] {
        guard !range.isEmpty else { return [] }
        var pieces: [(index: Int, range: Range<Int>)] = []
        var start = 0
        for (index, length) in lengths.enumerated() {
            let end = start + length
            let low = max(range.lowerBound, start)
            let high = min(range.upperBound, end)
            if low < high { pieces.append((index, (low - start)..<(high - start))) }
            if range.upperBound <= end { break }
            start = end + separator
        }
        return pieces
    }
}
