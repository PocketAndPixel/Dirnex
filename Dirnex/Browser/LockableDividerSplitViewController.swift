import AppKit

/// An `NSSplitViewController` whose divider can be taken out of service while something covers it.
///
/// A full-size Quick View is pinned over the panes as a *sibling* of the split view, so it hides the
/// divider without disabling it: `NSSplitView` keeps its own drag region and its resize cursor there
/// regardless of what is drawn on top. The symptom is a `< | >` cursor sitting over a photograph,
/// and a drag that resizes two panes nobody can see — found by dragging across the middle of a
/// full-window preview and watching the divider land 250 pt away once the preview was dismissed.
///
/// Emptying the divider's *effective rect* is the documented lever and the only one that withdraws
/// the cursor along with the drag; hiding or disabling the split view would take the panes with it.
@MainActor
class LockableDividerSplitViewController: NSSplitViewController {
    /// Set while something is covering this split's divider. Invalidating the cursor rects is what
    /// makes the change visible immediately — without it the resize cursor lingers until the pointer
    /// next leaves and re-enters the region.
    var isDividerLocked = false {
        didSet {
            guard isDividerLocked != oldValue else { return }
            splitView.window?.invalidateCursorRects(for: splitView)
        }
    }

    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        guard !isDividerLocked else { return .zero }
        return super.splitView(
            splitView,
            effectiveRect: proposedEffectiveRect,
            forDrawnRect: drawnRect,
            ofDividerAt: dividerIndex
        )
    }
}
