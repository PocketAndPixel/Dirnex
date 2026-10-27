import AppKit
import DirnexCore

/// The text view of one compare pane (PLAN.md §M31 Slice 3): read-only, one row per line, and
/// able to say which row is where.
///
/// Rows are found through TextKit 2's layout fragments rather than by arithmetic. Each row is one
/// fragment, and a fragment's frame is where TextKit actually put it, while `row × height` holds only
/// near the top of a document: measured 2026-10-22 on 100 000 rows, row 1 000 sat at 14 716 in one
/// document and 15 609 in another, against 16 000 by arithmetic (docs/NOTES.md ▸ Text fields and
/// text views). Nothing here reads `layoutManager`, which would drop the view to TextKit 1.
@MainActor
final class CompareTextView: NSTextView {
    /// What the view shows, for copying and for finding rows.
    var pane: ComparisonPaneText?
    /// Where ⌘C writes. A seam, so a test does not overwrite the clipboard of whoever runs it.
    var pasteboard = NSPasteboard.general
    /// Called when the view takes the keyboard, by a click or by Tab.
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    /// ⌘C copies the file's own text: gaps give nothing, a line cut short in the pane is copied
    /// whole, and each line ends as it did in the file.
    override func copy(_ sender: Any?) {
        guard let pane else {
            super.copy(sender)
            return
        }
        let selection = selectedRange()
        guard selection.location != NSNotFound, selection.length > 0 else { return }
        let text = pane.originalText(for: selection.location..<NSMaxRange(selection))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Rows and positions

    /// The row at the top of the visible area, and how far down into it the top edge is.
    func rowAtTop() -> (row: Int, offset: CGFloat)? {
        guard let pane, let fragment = fragment(atY: visibleRect.minY) else { return nil }
        let row = pane.row(containingUTF16Offset: offset(of: fragment))
        let top = fragment.layoutFragmentFrame.minY + textContainerOrigin.y
        return (row, visibleRect.minY - top)
    }

    /// The rows at least partly visible.
    ///
    /// Below the last row there is no fragment, so a pane showing the end of its text is visible
    /// down to the last row. Seen live 2026-10-26 in the merge window (PLAN.md §M34 Slice 3): taking
    /// the first row instead left the bands marking no change below row 0, and the overview strip
    /// outlining a sliver at its top, in any comparison shorter than the window. Further up a long
    /// text it stays the first row, so the band never lays out every change below the screen.
    func visibleRows() -> ClosedRange<Int>? {
        guard let pane, let first = fragment(atY: visibleRect.minY) else { return nil }
        let firstRow = pane.row(containingUTF16Offset: offset(of: first))
        let lastRow = if let last = fragment(atY: visibleRect.maxY - 1) {
            pane.row(containingUTF16Offset: offset(of: last))
        } else if visibleRect.maxY >= bounds.maxY - 1 {
            pane.rowStarts.count - 1
        } else {
            firstRow
        }
        return firstRow...max(firstRow, lastRow)
    }

    /// The top of row `row` in this view's coordinates, laying it out if it is not yet.
    func top(ofRow row: Int) -> CGFloat? {
        guard let pane, pane.rowStarts.indices.contains(row),
              let manager = textLayoutManager, let content = manager.textContentManager,
              let location = content.location(
                  content.documentRange.location,
                  offsetBy: pane.rowStarts[row]
              )
        else { return nil }
        var top: CGFloat?
        manager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            top = fragment.layoutFragmentFrame.minY + textContainerOrigin.y
            return false
        }
        return top
    }

    /// Scroll so that row `row` starts `offset` points above the visible area's top edge.
    ///
    /// Far into a document the row's position is an estimate until the scroll lays it out, and
    /// laying it out can move it, so the scroll is checked and repeated a bounded number of times:
    /// measured in `CompareWindowTests`, a jump back up from row 19 000 to row 500 otherwise landed
    /// on row 499.
    func scroll(toRow row: Int, offset: CGFloat, x: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        for _ in 0..<3 {
            guard let top = top(ofRow: row) else { return }
            let target = NSPoint(x: x, y: max(0, top + offset))
            clip.scroll(
                to: clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin
            )
            enclosingScrollView?.reflectScrolledClipView(clip)
            textLayoutManager?.textViewportLayoutController.layoutViewport()
            guard let landed = rowAtTop(), landed.row != row || abs(landed.offset - offset) > 0.5 else { return }
            // At the end of the document there is nowhere further to scroll, and that is not a miss.
            guard clip.bounds.maxY < frame.maxY - 0.5 else { return }
        }
    }

    /// Calls `body` with each row on screen and its top, in this view's coordinates.
    func forEachVisibleRow(_ body: (_ row: Int, _ top: CGFloat) -> Void) {
        guard let pane, let manager = textLayoutManager, let first = fragment(atY: visibleRect.minY)
        else { return }
        let bottom = visibleRect.maxY
        let start = first.rangeInElement.location
        manager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let top = fragment.layoutFragmentFrame.minY + textContainerOrigin.y
            guard top < bottom else { return false }
            body(pane.row(containingUTF16Offset: offset(of: fragment)), top)
            return true
        }
    }

    private func fragment(atY y: CGFloat) -> NSTextLayoutFragment? {
        textLayoutManager?.textLayoutFragment(
            for: CGPoint(x: 0, y: max(0, y - textContainerOrigin.y))
        )
    }

    private func offset(of fragment: NSTextLayoutFragment) -> Int {
        guard let content = textLayoutManager?.textContentManager else { return 0 }
        return content.offset(
            from: content.documentRange.location,
            to: fragment.rangeInElement.location
        )
    }
}
