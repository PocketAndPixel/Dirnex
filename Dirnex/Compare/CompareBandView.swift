import AppKit

/// The strip between the two panes (PLAN.md §M31 Slice 3): a mark beside each change on screen, in
/// the color of what the change does, and a stronger one for the change the keyboard went to last.
///
/// The panes are level row for row, so a change occupies the same rows on both sides and its mark
/// is a straight bar rather than FileMerge's slanted band: the gaps already do the work the slant
/// does there. Row positions come from the left pane, which is level with the right.
@MainActor
final class CompareBandView: NSView {
    weak var textView: CompareTextView?
    var changeRows: [Range<Int>] = []
    var kinds: [CompareChangeKind] = []
    var current: Int?

    static let width: CGFloat = 14

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        guard let textView, let visible = textView.visibleRows(),
              let context = NSGraphicsContext.current?.cgContext else { return }
        var index = Self.firstChange(endingAfter: visible.lowerBound, in: changeRows)
        while index < changeRows.count, changeRows[index].lowerBound <= visible.upperBound {
            let rows = changeRows[index]
            let first = max(rows.lowerBound, visible.lowerBound)
            let last = min(rows.upperBound - 1, visible.upperBound)
            if let top = textView.top(ofRow: first), let lastTop = textView.top(ofRow: last) {
                let start = convert(NSPoint(x: 0, y: top), from: textView).y
                let end = convert(NSPoint(x: 0, y: lastTop), from: textView).y + CompareTextStyle.lineHeight
                context.saveGState()
                context.setAlpha(index == current ? 1 : 0.45)
                let kind = kinds.indices.contains(index) ? kinds[index] : CompareChangeKind.change
                CompareColors.mark(for: kind).setFill()
                let bar = NSRect(x: 4, y: start, width: bounds.width - 8, height: end - start)
                NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
                context.restoreGState()
            }
            index += 1
        }
    }

    /// The first change that ends after `row`, by binary search.
    static func firstChange(endingAfter row: Int, in changeRows: [Range<Int>]) -> Int {
        var low = 0
        var high = changeRows.count
        while low < high {
            let middle = (low + high) / 2
            if changeRows[middle].upperBound > row {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}
