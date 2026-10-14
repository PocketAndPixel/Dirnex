import AppKit

/// A table with alternating rows whose stripes below the last row stay in step with the rows above
/// them. Every striped table in the app is one of these, or a ``StripedOutlineView``; see
/// ``TableFillerRepaint`` for what goes wrong in a plain `NSTableView`.
class StripedTableView: NSTableView {
    private let fillerRepaint = TableFillerRepaint()

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        fillerRepaint.watch(subview)
    }

    override func willRemoveSubview(_ subview: NSView) {
        fillerRepaint.unwatch(subview)
        super.willRemoveSubview(subview)
    }
}

/// ``StripedTableView`` for an outline: the same fix, since an outline is a table underneath.
class StripedOutlineView: NSOutlineView {
    private let fillerRepaint = TableFillerRepaint()

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        fillerRepaint.watch(subview)
    }

    override func willRemoveSubview(_ subview: NSView) {
        fillerRepaint.unwatch(subview)
        super.willRemoveSubview(subview)
    }
}

/// Repaints, whole, every view a table lays among its rows whenever that view's frame changes.
///
/// AppKit does not draw the empty space under a striped table's rows itself: it lays a private
/// `NSTableBackgroundView` there, from the last row down to the table's bottom, and moves it on
/// every layout. That view repaints all of itself on a resize only when it grows past the **largest
/// size it was last drawn at** (read off its `setFrameSize:`, which compares against a size its
/// `drawRect:` records). So when the table's height changes between two draws (the terminal drawer,
/// a window resize) and the table then loses rows, the view grows back inside a size it has
/// "already drawn". Only the old bounds are repainted, by `reloadData`, and the bottom band keeps
/// the old pixels, which belong to rows that are no longer there. When an odd number of rows went
/// away, that band's stripes run the wrong way round: two dark rows in a row with a sliver of a
/// light one between them, sitting on the table's bottom edge, as tall as the rows that went.
/// Measured 2026-10-14 in a scratch table (10 rows, the pane 100 pt shorter, then 7 rows) and in a
/// file pane (drawer open, Common up to Dev); a resize cleared it, which is why it came and went.
///
/// So any frame change repaints the whole view, origin moves included, since a move alone shifts
/// the retained pixels just the same. Every subview but the rows is watched rather than that one
/// class by name: a repaint of something else that moved costs a few fills and nothing more.
@MainActor
final class TableFillerRepaint: NSObject {
    func watch(_ subview: NSView) {
        // Rows redraw themselves as they are reused; only what AppKit lays around them needs this.
        guard !(subview is NSTableRowView) else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(subviewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: subview
        )
    }

    func unwatch(_ subview: NSView) {
        NotificationCenter.default.removeObserver(
            self, name: NSView.frameDidChangeNotification, object: subview
        )
    }

    @objc private func subviewFrameDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSView else { return }
        view.setNeedsDisplay(view.bounds)
    }
}
