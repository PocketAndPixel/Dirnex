import Foundation

/// Everything the compare window shows for two texts: the rows, where each change sits among
/// them, and what differs that no row can show (PLAN.md §M31 Slice 2).
///
/// Built once, off the main thread, from two `ComparedText`s; the window only reads it.
public struct TextComparison: Sendable {
    public let leftLines: [TextLine]
    public let rightLines: [TextLine]
    public let options: LineDiffOptions
    public let diff: LineDiff
    /// Both panes' rows, level with each other (`AlignedRow`).
    public let rows: [AlignedRow]
    /// The rows of each change, in order, for moving from one change to the next.
    public let changeRows: [Range<Int>]
    /// Differences between the two files that the rows do not show, in a fixed order.
    public let unshownDifferences: [UnshownDifference]

    /// A difference the rows cannot show: in the bytes that encode the text, or one the options
    /// told the comparison to overlook.
    ///
    /// When `diff` is identical this is the whole answer to "why do these files differ", which the
    /// window must give rather than show two columns with nothing marked. When it is not, it is
    /// still worth a line: two files in different encodings compare by their text, and the reader
    /// should know that is what happened.
    public enum UnshownDifference: Sendable, Hashable {
        /// The two files are in different encodings.
        case encoding(left: String.Encoding, right: String.Encoding)
        /// One file opens with a byte-order mark and the other does not.
        case byteOrderMark(left: Bool, right: Bool)
        /// Lines shown as the same end differently, because the options overlook line endings.
        case lineEndings
        /// Lines shown as the same differ in whitespace, because the options overlook it.
        case whitespace
        /// Lines shown as the same differ in case, because the options overlook it.
        case letterCase
    }

    public init(
        _ left: ComparedText,
        _ right: ComparedText,
        options: LineDiffOptions = LineDiffOptions()
    ) {
        let leftLines = TextLines.split(left.text)
        let rightLines = TextLines.split(right.text)
        let diff = LineDiff.compare(leftLines, rightLines, options: options)
        let layout = RowAlignment.layout(
            left: leftLines,
            right: rightLines,
            diff: diff,
            options: options
        )
        self.leftLines = leftLines
        self.rightLines = rightLines
        self.options = options
        self.diff = diff
        rows = layout.rows
        changeRows = layout.changeRows
        unshownDifferences = Self.unshownDifferences(
            left,
            right,
            rows: layout.rows,
            lines: (leftLines, rightLines),
            options: options
        )
    }

    // MARK: - Moving between changes

    /// The first change that starts below `row`, or `nil` past the last one. Pass `-1` for the
    /// first change of all.
    public func change(after row: Int) -> Range<Int>? {
        changeRows.first { $0.lowerBound > row }
    }

    /// The last change that starts above `row`, or `nil` before the first one. From inside a change,
    /// that is the one before it.
    public func change(before row: Int) -> Range<Int>? {
        changeRows.last { $0.lowerBound < row }
    }

    /// The position of the change holding `row` among all of them, for "change 3 of 12".
    public func changeIndex(containing row: Int) -> Int? {
        changeRows.firstIndex { $0.contains(row) }
    }

    // MARK: - What the rows do not show

    private static func unshownDifferences(
        _ left: ComparedText,
        _ right: ComparedText,
        rows: [AlignedRow],
        lines: (left: [TextLine], right: [TextLine]),
        options: LineDiffOptions
    ) -> [UnshownDifference] {
        var found: [UnshownDifference] = []
        if left.encoding != right.encoding {
            found.append(.encoding(left: left.encoding, right: right.encoding))
        }
        if left.hasByteOrderMark != right.hasByteOrderMark {
            found.append(.byteOrderMark(left: left.hasByteOrderMark, right: right.hasByteOrderMark))
        }
        var lineEndings = false
        var whitespace = false
        var letterCase = false
        // Each part of the options alone, with line endings out of the key, so a pair of lines that
        // matched can be asked which of them it needed.
        let caseOnly = LineDiffOptions(ignoresLineEndings: true, ignoresCase: true)
        let whitespaceOnly = LineDiffOptions(
            whitespace: options.whitespace,
            ignoresLineEndings: true
        )
        for row in rows where row.kind == .same {
            guard let leftIndex = row.left, let rightIndex = row.right else { continue }
            let leftLine = lines.left[leftIndex]
            let rightLine = lines.right[rightIndex]
            lineEndings = lineEndings || row.lineEndingsDiffer
            guard !leftLine.content.utf8.elementsEqual(rightLine.content.utf8) else { continue }
            if caseOnly.key(for: leftLine) == caseOnly.key(for: rightLine) {
                letterCase = true
            } else if whitespaceOnly.key(for: leftLine) == whitespaceOnly.key(for: rightLine) {
                whitespace = true
            } else {
                letterCase = true
                whitespace = true
            }
        }
        if lineEndings {
            found.append(.lineEndings)
        }
        if whitespace {
            found.append(.whitespace)
        }
        if letterCase {
            found.append(.letterCase)
        }
        return found
    }
}
