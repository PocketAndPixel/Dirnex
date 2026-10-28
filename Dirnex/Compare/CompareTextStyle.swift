import AppKit
import DirnexCore

/// How a compare pane sets its text (PLAN.md §M31 Slice 3).
///
/// **Every row is one line of one fixed height, and no line wraps.** The panes are kept level row by
/// row (`CompareScrollSync`), and that holds only while a row is the same height on both sides: a
/// line that wrapped, or one that a fallback font for an emoji made taller, would push every row
/// below it out of line with the other pane. So the paragraph style pins the height and clips rather
/// than wraps, and the pane is made as wide as its widest row (`documentWidth`).
///
/// Not wrapping is also what keeps TextKit 2 lazy here. A text view that resizes itself to its
/// widest line has to lay out every line to find it; measured 2026-10-22 on 100 000 rows, it was
/// still typesetting after ten minutes, where a fixed width shows the same document at once
/// (docs/NOTES.md ▸ Text fields and text views).
@MainActor
enum CompareTextStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let lineHeight = ceil(font.ascender - font.descender + font.leading)
    /// One column of the monospaced font.
    static let columnWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width * 100) / 100

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        // A tab stops every four columns, as `ComparisonPaneText.columns(of:)` counts it.
        style.tabStops = []
        style.defaultTabInterval = columnWidth * 4
        style.lineBreakMode = .byClipping
        return style
    }()

    /// Past this many UTF-16 units a pane is shown without syntax colors, the size Quick View reads
    /// and colors at most.
    static let syntaxColoringLimit = TextPreview.byteLimit

    /// How wide a pane's text has to be to show its widest row on one line. Wide characters are
    /// counted as two columns, which an emoji's real advance can exceed a little, so there is room
    /// to spare: a row that ran out of width would be clipped, never wrapped.
    static func documentWidth(for pane: ComparisonPaneText, padding: CGFloat) -> CGFloat {
        ceil(CGFloat(pane.widestColumns) * columnWidth * 1.15 + 2 * padding + 40)
    }

    /// How each row of `side` is painted.
    static func fills(for side: ComparisonPaneText.Side, rows: [AlignedRow]) -> [AlignedRowFill] {
        rows.map { row in
            let index = side == .left ? row.left : row.right
            guard index != nil else { return .gap }
            switch row.kind {
            case .same: return .same
            case .removed, .inserted, .changed: return side == .left ? .removed : .inserted
            }
        }
    }

    /// What each change does, in the order of `TextComparison.changeRows`.
    static func changeKinds(_ comparison: TextComparison) -> [CompareChangeKind] {
        comparison.changeRows.map { rows in
            let kinds = Set(comparison.rows[rows].map(\.kind))
            if kinds == [.removed] {
                return .removal
            }
            if kinds == [.inserted] {
                return .insertion
            }
            return .change
        }
    }

    /// A pane's text, colored: syntax tokens for the foreground, and the words that differ inside a
    /// changed row marked behind them. A row's own background is not here; the row draws it across
    /// the whole pane (`CompareRowFragment`).
    static func document(
        for pane: ComparisonPaneText,
        rows: [AlignedRow],
        tokens: [SyntaxToken]
    ) -> NSAttributedString {
        let document = NSMutableAttributedString(
            string: pane.text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph
            ]
        )
        let length = document.length
        for token in tokens {
            // In order and in range by the core's promise; a mismatch fails as a missing color
            // rather than as an exception, as in Quick View.
            guard token.end <= length else { break }
            guard let color = SyntaxTheme.color(for: token.kind) else { continue }
            document.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: token.offset, length: token.length)
            )
        }
        let wordColor = pane.side == .left ? CompareColors.removedWords : CompareColors.insertedWords
        for (row, aligned) in rows.enumerated() {
            guard let inline = aligned.inline else { continue }
            let rowRange = pane.range(ofRow: row)
            for range in pane.side == .left ? inline.left : inline.right {
                // A line cut short in the pane shows only the start of what differs in it.
                let start = rowRange.lowerBound + range.lowerBound
                let end = min(rowRange.lowerBound + range.upperBound, rowRange.upperBound)
                guard start < end else { continue }
                document.addAttribute(
                    .backgroundColor,
                    value: wordColor,
                    range: NSRange(location: start, length: end - start)
                )
            }
        }
        return document
    }
}
