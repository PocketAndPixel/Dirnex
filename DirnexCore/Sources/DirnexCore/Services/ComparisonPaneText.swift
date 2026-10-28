import Foundation

/// One pane of the compare window as the text its view holds (PLAN.md §M31 Slice 3).
///
/// Every row of the comparison is one line here, and a gap is an empty line, so both panes have the
/// same number of lines and row `n` is line `n` in each. That is what lets the window keep the two
/// level by row, which it has to: under TextKit 2 a line's position far into a document is an
/// estimate that differs between two documents with different text, so the two panes cannot simply
/// share a scroll offset (docs/NOTES.md ▸ Text fields and text views).
///
/// The text is the file's own, with two changes that keep one row one line:
/// - **A character a text view breaks a line at becomes a visible stand-in**: U+2028, U+2029 and
///   U+0085 show as `␤`, a vertical tab as `␋`, a form feed as `␌`. Each is one UTF-16 unit, like
///   what it replaces, so offsets into the file's line still hold.
/// - **A line longer than `maximumShownLength` is cut, and ends in `…`.** A pane does not wrap, and a
///   minified file is one line of megabytes.
///
/// Copying goes the other way (`originalText(for:)`): a selection gives the file's own text, gaps
/// give nothing, and each line ends as it did in the file.
///
/// A pane is any text's lines laid out on shared rows, so the merge window's panes, three or four
/// of them, are built the same way (`init(lines:rows:)`, PLAN.md §M34 Slice 2).
public struct ComparisonPaneText: Sendable {
    public enum Side: Sendable {
        case left
        case right
    }

    /// The longest line shown whole, in UTF-16 units: the same bound as `InlineDiff`'s.
    public static let maximumShownLength = InlineDiff.maximumLineLength

    /// The side of a two-way comparison this pane shows, or `nil` for a pane of the merge window.
    public let side: Side?
    /// What the pane's text view holds: one line per row, each ending in `\n`, the last included.
    /// TextKit 2 gives an empty last line no paragraph of its own, so a gap at the end would
    /// otherwise have no line to be drawn on.
    public let text: String
    /// Where each row starts in `text`, in UTF-16 units, which is what a text view's ranges count.
    public let rowStarts: [Int]
    /// The widest row in columns: a tab moves to the next multiple of four, and a wide character
    /// (CJK, an emoji) counts two. A pane that does not wrap is sized from it.
    public let widestColumns: Int

    private let lines: [TextLine]
    /// The file line each row shows, `nil` for a gap.
    private let lineOfRow: [Int?]
    /// `text`'s length in UTF-16 units.
    private let utf16Length: Int

    public init(_ comparison: TextComparison, side: Side) {
        self.init(
            lines: side == .left ? comparison.leftLines : comparison.rightLines,
            lineOfRow: comparison.rows.map { side == .left ? $0.left : $0.right },
            side: side
        )
    }

    /// A pane showing `lines` on shared rows: `rows[n]` is the line row `n` shows, `nil` for a gap.
    public init(lines: [TextLine], rows: [Int?]) {
        self.init(lines: lines, lineOfRow: rows, side: nil)
    }

    private init(lines: [TextLine], lineOfRow: [Int?], side: Side?) {
        self.side = side
        self.lines = lines
        self.lineOfRow = lineOfRow
        var text = ""
        var starts: [Int] = []
        starts.reserveCapacity(lineOfRow.count)
        var offset = 0
        var widest = 0
        for index in lineOfRow {
            starts.append(offset)
            if let index {
                let shown = Self.shown(lines[index].content)
                text += shown
                offset += shown.utf16.count
                widest = max(widest, Self.columns(of: shown))
            }
            text += "\n"
            offset += 1
        }
        self.text = text
        rowStarts = starts
        widestColumns = widest
        utf16Length = offset
    }

    /// The file line row `row` shows, or `nil` for a gap.
    public func lineIndex(ofRow row: Int) -> Int? {
        lineOfRow.indices.contains(row) ? lineOfRow[row] : nil
    }

    /// The row holding UTF-16 offset `offset` of `text`. An offset on a line break belongs to the
    /// row the break ends.
    public func row(containingUTF16Offset offset: Int) -> Int {
        var low = 0
        var high = rowStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if rowStarts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return max(low, 0)
    }

    /// Row `row`'s text in `text`, without the line break after it.
    public func range(ofRow row: Int) -> Range<Int> {
        let start = rowStarts[row]
        let end = (row + 1 < rowStarts.count ? rowStarts[row + 1] : utf16Length) - 1
        return start..<end
    }

    /// The file's own text for a selection of `text`: gaps give nothing, a line cut short gives the
    /// whole line once the selection reaches its end, and a line ends as it did in the file when the
    /// selection runs past it.
    public func originalText(for selection: Range<Int>) -> String {
        guard !rowStarts.isEmpty, !selection.isEmpty else { return "" }
        var copied = ""
        let first = row(containingUTF16Offset: selection.lowerBound)
        let last = row(containingUTF16Offset: max(selection.lowerBound, selection.upperBound - 1))
        for row in first...last {
            guard let index = lineOfRow[row] else { continue }
            let rowRange = range(ofRow: row)
            let line = lines[index]
            let from = max(selection.lowerBound, rowRange.lowerBound) - rowRange.lowerBound
            let reachesEnd = selection.upperBound >= rowRange.upperBound
            let to = reachesEnd ? line.content.utf16.count : selection.upperBound - rowRange.lowerBound
            copied += Self.slice(line.content, utf16: from..<max(from, to))
            if selection.upperBound > rowRange.upperBound {
                copied += line.terminator.text
            }
        }
        return copied
    }

    // MARK: - Shown text

    private static func shown(_ content: Substring) -> String {
        // Every character `standIn` replaces has a byte no other line needs looked at: `0x0B`,
        // `0x0C`, or the lead byte of U+0085 (`0xC2`) or of U+2028 and U+2029 (`0xE2`).
        let mayNeedStandIns = content.utf8.contains { $0 == 0x0B || $0 == 0x0C || $0 == 0xC2 || $0 == 0xE2 }
        var shown = mayNeedStandIns ? String(content.unicodeScalars.map(Self.standIn)) : String(
            content
        )
        if shown.utf16.count > maximumShownLength {
            let cut = String.Index(utf16Offset: maximumShownLength, in: shown)
            shown = String(shown[..<cut]) + "…"
        }
        return shown
    }

    /// A character that would break the line in a text view, as a visible symbol of the same width
    /// in UTF-16.
    private static func standIn(_ scalar: Unicode.Scalar) -> Character {
        switch scalar.value {
        case 0x2028, 0x2029, 0x85: "\u{2424}"
        case 0x0B: "\u{240B}"
        case 0x0C: "\u{240C}"
        default: Character(scalar)
        }
    }

    /// How many columns `text` takes in a monospaced pane.
    static func columns(of text: String) -> Int {
        var columns = 0
        for character in text {
            if character == "\t" {
                columns += 4 - columns % 4
            } else if let scalar = character.unicodeScalars.first, isWide(scalar) {
                columns += 2
            } else {
                columns += 1
            }
        }
        return columns
    }

    /// Whether a character starting with `scalar` takes two columns: East Asian wide and full-width
    /// characters, and emoji drawn as emoji.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation {
            return true
        }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    private static func slice(_ content: Substring, utf16 range: Range<Int>) -> Substring {
        let utf16 = content.utf16
        let count = utf16.count
        let lower = utf16.index(utf16.startIndex, offsetBy: min(range.lowerBound, count))
        let upper = utf16.index(utf16.startIndex, offsetBy: min(range.upperBound, count))
        return content[lower..<upper]
    }
}
