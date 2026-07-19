import AppKit

/// The places/volumes source list's table. A plain `NSTableView` becomes first responder the
/// moment it is clicked — including clicks in the empty space within its bounds or on a
/// non-selectable section header. That pulls keyboard focus away from the active file pane and,
/// because the pane's file commands are dispatched through the responder chain with a nil
/// target (see `MainMenuBuilder`), silently disables F5/F6/F8 until a pane is clicked again.
///
/// So a click is let through only when it lands on a real, selectable destination row — which
/// navigates the active pane and hands focus back to it anyway (`SidebarViewController`'s
/// `rowClicked` → `focusTable`). Empty space and header clicks instead run `onEmptyClick`, which
/// re-focuses the active pane. Right-click (the saved-search context menu) and the cells' own
/// eject/delete buttons are unaffected — they never route through this `mouseDown`.
final class SidebarTableView: NSTableView {
    /// Invoked for a click on empty space or a header — re-focus the active file pane.
    var onEmptyClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let isHeader = row >= 0 && (delegate?.tableView?(self, isGroupRow: row) ?? false)
        guard row >= 0, !isHeader else {
            onEmptyClick?()
            return
        }
        super.mouseDown(with: event)
    }
}

/// The source list's clip view. The table only spans its own rows, so a click in the empty area
/// *below* the last row lands here rather than on `SidebarTableView`. Left to the default
/// behavior it still pulls focus off the active file pane, so we catch it and re-focus the pane
/// via `onBackgroundClick`. A click on a real row lands on the table (a deeper hit-test result),
/// so this only ever fires for genuine empty space.
final class SidebarClipView: NSClipView {
    /// Invoked for a click in the empty area below the rows — re-focus the active file pane.
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}
