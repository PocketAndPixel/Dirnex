import Foundation

/// One edit to a document's lines: those in `range` are replaced by `replacement` (PLAN.md §M33
/// Slice 1).
///
/// Every edit the compare window makes has this shape, and so does its inverse, which puts the
/// removed lines back in place of the replacement. So undo and redo are one operation:
/// `ComparedDocument.apply(_:)` returns the edit that reverses the one it applied, and applying that
/// returns the original again.
public struct LineEdit: Sendable {
    /// The lines replaced, as indices into the document before the edit.
    public let range: Range<Int>
    public let replacement: [TextLine]

    public init(range: Range<Int>, replacement: [TextLine]) {
        self.range = range
        self.replacement = replacement
    }

    /// The edit that copies `change` across to `side`: the lines `side` has there give way to the
    /// other side's. `change` comes from comparing `left` and `right` as they stand now.
    ///
    /// The copied lines take the destination's `commonLineEnding`, so a block copied out of a CRLF
    /// file does not bring CRLF into an LF one. A line with none, which can only be the last of its
    /// file, gains one unless it lands last too. And a block that lands after a last line with no
    /// line break gives that line one as well, since without it the two lines would join; only an
    /// option that overlooks line endings can leave a change there.
    public static func copying(
        _ change: LineDiff.Change,
        to side: ComparisonPaneText.Side,
        left: ComparedDocument,
        right: ComparedDocument
    ) -> LineEdit {
        let (source, copiedRange, destination, replaced) = side == .right
            ? (left, change.left, right, change.right)
            : (right, change.right, left, change.left)
        let ending = destination.commonLineEnding ?? source.commonLineEnding ?? .lf
        let landsLast = replaced.upperBound == destination.lines.count
        var copied = source.lines[copiedRange].map { line in
            TextLine(
                content: line.content,
                terminator: line.terminator == .none && landsLast ? .none : ending
            )
        }
        var range = replaced
        if !copied.isEmpty, range.lowerBound > 0 {
            let before = destination.lines[range.lowerBound - 1]
            if before.terminator == .none {
                copied.insert(TextLine(content: before.content, terminator: ending), at: 0)
                range = range.lowerBound - 1..<range.upperBound
            }
        }
        return LineEdit(range: range, replacement: copied)
    }
}
