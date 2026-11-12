import AppKit
import DirnexCore

/// The byte view's measurements (PLAN.md §M37 Slice 2).
///
/// Everything is a whole number of columns of one monospaced font, so a byte's place in a row is
/// arithmetic rather than something to measure.
@MainActor
enum BinaryCompareStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// One column of the monospaced font.
    static let columnWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width * 100) / 100
    static let rowHeight = ceil(font.ascender - font.descender + font.leading) + 1
    /// Between a cell's edge and its text.
    static let padding: CGFloat = 8
    /// Columns between a side's hex and its characters.
    static let charactersGap = 2

    /// Where a side's characters start, in columns from its text's start.
    static var charactersStart: Int {
        BinaryHexLayout.hexLength + charactersGap
    }

    /// How wide one side's column is.
    static var sideWidth: CGFloat {
        CGFloat(charactersStart + BinaryHexLayout.bytesPerRow) * columnWidth + 2 * padding
    }

    /// How wide the offset column is for offsets of `digits` digits.
    static func offsetWidth(digits: Int) -> CGFloat {
        CGFloat(digits) * columnWidth + 2 * padding
    }

    /// The most rows the table can show. Measured 2026-11-08: an `NSTableView` is exact down to the
    /// point up to a height of 2^44 points, and past it the clip view stops, so the end of a taller
    /// table cannot be reached. At this row height that is more than 15 TiB of file. It takes
    /// `BinaryHexTable` to get that far.
    static var maximumRows: Int {
        (1 << 44) / Int(rowHeight) - 1
    }

    /// How one side's row is painted behind its text, or `nil` for a row the two sides agree on.
    static func fill(for row: BinaryHexRow, side: ComparisonPaneText.Side) -> NSColor? {
        guard !row.differingColumns.isEmpty else { return nil }
        if (side == .left ? row.left : row.right).isEmpty {
            return CompareColors.gapRow
        }
        return side == .left ? CompareColors.removedRow : CompareColors.insertedRow
    }
}

/// The byte view's table, kept out of Auto Layout's sums (PLAN.md §M37 Slice 2).
///
/// **Auto Layout cannot hold a constant over 10^10 points, and it substitutes a smaller one.** A
/// table's intrinsic height is its row count times its row height, so with 16 points a row, a file
/// past about 9 GiB comes back from the first layout pass with its table cut to 10^10 points, and
/// its end out of reach. Nothing fails: the rows up to there are right, and the scroller just stops
/// short. Measured 2026-11-08 at 2^36 rows through five resizes. With no intrinsic size, and no
/// autoresizing constraints to take its place (`translatesAutoresizingMaskIntoConstraints` off), the
/// layout engine has no constraint on the table's height at all, and the table sizes itself as it
/// always has.
@MainActor
final class BinaryHexTable: NSTableView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // A table's own accessibility children are every row. Crashed 2026-11-08 on a 20 GiB pair the
    // moment an accessibility client read them: AppKit asks for an array of 1.3 billion items and
    // Core Foundation aborts with "size unreasonably big". So what is on screen is offered as all of
    // them, which is all a reader can act on anyway; moving the selection brings more on screen.
    //
    // The elements have to be AppKit's own row proxies, each row view's accessibility parent. A row
    // view is not one: it answers `false` to `isAccessibilityElement`, and a real client handed row
    // views found nothing behind them. Nor can the proxies be read as `accessibilityVisibleRows`
    // types them: they do not conform to `NSAccessibilityRow`, and touching one as such traps
    // ("NSArray element failed to match the Swift Array Element type"), so that array is only ever
    // passed along.

    override func accessibilityChildren() -> [Any]? {
        let range = rows(in: visibleRect)
        let onScreen = (range.location..<NSMaxRange(range)).compactMap {
            rowView(atRow: $0, makeIfNecessary: false)?.accessibilityParent()
        }
        return (headerView.map { [$0] } ?? []) + onScreen
    }

    override func accessibilityRows() -> [any NSAccessibilityRow]? {
        super.accessibilityVisibleRows()
    }
}

/// One cell of the byte view (PLAN.md §M37 Slice 2): a row's offset, or one side's hex and characters
/// with the bytes that differ marked.
///
/// The whole cell is drawn rather than built from labels, so a screenful of rows is a few dozen
/// strings and nothing to lay out.
@MainActor
final class BinaryHexCell: NSTableCellView {
    /// What a cell shows.
    enum Content: Equatable {
        case none
        case offset(String)
        /// One side of a row. `nil` until the row's page has been read, which draws blank.
        case side(BinaryHexRow?, ComparisonPaneText.Side)
    }

    static let identifier = NSUserInterfaceItemIdentifier("BinaryHexCell")

    var content = Content.none {
        didSet { needsDisplay = true }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    /// Whether this row is the table's selected one in the key window, which is drawn in the
    /// accent color and so takes light text and no row fill.
    private var isEmphasized: Bool {
        backgroundStyle == .emphasized
    }

    private var textColor: NSColor {
        isEmphasized ? .alternateSelectedControlTextColor : .textColor
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .none:
            break
        case let .offset(text):
            drawText(text, color: isEmphasized ? textColor : .secondaryLabelColor)
        case let .side(row, side):
            guard let row else { return }
            if !isEmphasized, let fill = BinaryCompareStyle.fill(for: row, side: side) {
                fill.setFill()
                bounds.fill()
            }
            markDifferences(in: row, side: side)
            drawText(Self.text(of: row, side: side), color: textColor)
        }
    }

    /// One side as the cell draws it: hex, then characters.
    static func text(of row: BinaryHexRow, side: ComparisonPaneText.Side) -> String {
        row.hexText(side) + String(repeating: " ", count: BinaryCompareStyle.charactersGap)
            + row.characterText(side)
    }

    private func drawText(_ text: String, color: NSColor) {
        let font = BinaryCompareStyle.font
        (text as NSString).draw(
            at: NSPoint(x: BinaryCompareStyle.padding, y: 0),
            withAttributes: [.font: font, .foregroundColor: color]
        )
    }

    /// Mark each byte this side has that differs, in its hex and in its characters. A byte only the
    /// other side has leaves nothing here to mark, and the row's gap color says so.
    private func markDifferences(in row: BinaryHexRow, side: ComparisonPaneText.Side) {
        let count = (side == .left ? row.left : row.right).count
        let color = side == .left ? CompareColors.removedWords : CompareColors.insertedWords
        (isEmphasized ? NSColor.white.withAlphaComponent(0.28) : color).setFill()
        for column in row.differingColumns where column < count {
            let hex = BinaryHexLayout.hexRange(ofColumn: column)
            rect(columns: hex.lowerBound..<hex.upperBound).fill()
            let character = BinaryCompareStyle.charactersStart + column
            rect(columns: character..<(character + 1)).fill()
        }
    }

    private func rect(columns: Range<Int>) -> NSRect {
        let width = BinaryCompareStyle.columnWidth
        return NSRect(
            x: BinaryCompareStyle.padding + CGFloat(columns.lowerBound) * width,
            y: 0,
            width: CGFloat(columns.count) * width,
            height: bounds.height
        )
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    override func accessibilityValue() -> Any? {
        switch content {
        case .none: ""
        case let .offset(text): text
        case let .side(row, side): row.map { Self.text(of: $0, side: side) } ?? ""
        }
    }
}
