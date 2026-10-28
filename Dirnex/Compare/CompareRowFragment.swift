import AppKit
import DirnexCore

/// One line of a compare pane, which paints its row's color across the whole pane before drawing its
/// text (PLAN.md §M31 Slice 3).
///
/// A row's color has to reach both edges of the pane and has to be there on an empty line, where a
/// gap is drawn, so it cannot be a text attribute: a background attribute covers only the glyphs.
/// The fragment is TextKit 2's own unit of drawing, and its position is the one place a row's
/// position is known for certain. Under TextKit 2 that is an estimate anywhere it has not laid out,
/// so a background computed as `row × height` would drift from the text it belongs to.
final class CompareRowFragment: NSTextLayoutFragment {
    /// The row's color, or `nil` for a row that is the same on both sides.
    var fill: NSColor?

    /// Wide enough to paint the row from the container's left edge to its right.
    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        guard fill != nil, let width = textLayoutManager?.textContainer?.size.width else { return bounds }
        return bounds.union(
            CGRect(x: -layoutFragmentFrame.minX, y: 0, width: width, height: rowHeight)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let fill, let width = textLayoutManager?.textContainer?.size.width {
            context.saveGState()
            context.setFillColor(fill.cgColor)
            context.fill(
                CGRect(
                    x: point.x - layoutFragmentFrame.minX,
                    y: point.y,
                    width: width,
                    height: rowHeight
                )
            )
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }

    /// The row's own line. The last paragraph of a text ending in a line break carries the empty line
    /// after it as a second line, which belongs to no row.
    private var rowHeight: CGFloat {
        textLineFragments.first?.typographicBounds.height ?? layoutFragmentFrame.height
    }
}

/// Hands TextKit 2 a `CompareRowFragment` for every line of a pane, colored by its row.
///
/// The fragment method is an optional Objective-C requirement, which Swift 6 can satisfy without
/// emitting the method on a main-actor class (docs/NOTES.md ▸ Delegates in Swift 6), so
/// `CompareWindowTests` asserts that the class answers its selector. It is not main-actor isolated
/// because the protocol is not; TextKit calls it on the main thread, where the pane updates it.
final class CompareRowColoring: NSObject, NSTextLayoutManagerDelegate {
    private var fills: [AlignedRowFill] = []
    private var rowStarts: [Int] = []

    func update(fills: [AlignedRowFill], rowStarts: [Int]) {
        self.fills = fills
        self.rowStarts = rowStarts
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = CompareRowFragment(textElement: textElement, range: textElement.elementRange)
        if let content = textLayoutManager.textContentManager {
            let offset = content.offset(from: content.documentRange.location, to: location)
            fragment.fill = CompareColors.rowFill(fill(atOffset: offset))
        }
        return fragment
    }

    /// The fill of the row holding UTF-16 offset `offset`.
    func fill(atOffset offset: Int) -> AlignedRowFill {
        guard !rowStarts.isEmpty else { return .same }
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
        return fills.indices.contains(low) ? fills[low] : .same
    }
}
