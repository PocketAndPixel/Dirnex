import AppKit

/// The places/volumes source list's table. A plain `NSTableView` becomes first responder the
/// moment it is clicked — including clicks in the empty space within its bounds or on a
/// non-selectable section header. That pulls keyboard focus away from the active file pane and,
/// because the pane's file commands are dispatched through the responder chain with a nil
/// target (see `MainMenuBuilder`), silently disables F5/F6/F8 until a pane is clicked again.
///
/// So a click is let through only when it lands on a real, selectable destination row — which
/// navigates the active pane and hands focus back to it anyway (`SidebarViewController`'s
/// `rowClicked` → `focusTable`). Empty space runs `onEmptyClick` and a header runs
/// `onHeaderClick`, both of which re-focus the active pane. Right-click (the saved-search context
/// menu) and the cells' own eject/delete buttons are unaffected — they never route through this
/// `mouseDown`.
final class SidebarTableView: NSTableView {
    /// Invoked for a click on empty space — re-focus the active file pane.
    var onEmptyClick: (() -> Void)?
    /// Invoked with the row index for a click anywhere on a section header — fold or unfold that
    /// section (PLAN.md §M8). The whole header is the hit target, not just its triangle: a 9-point
    /// chevron is a mean thing to ask anyone to hit, and the header has no other click behavior to
    /// compete with.
    var onHeaderClick: ((Int) -> Void)?

    // Keyboard commands the focused sidebar forwards to its controller (PLAN.md §M8 "Keyboard
    // access to the sidebar"). Row movement (↑/↓) and type-select are left to `NSTableView`; only
    // the file-manager-specific keys are intercepted. All are `nil` until the controller wires them.
    /// Return / Enter — activate the selected row (navigate a place, run a search, fold a header).
    var onActivateSelection: (() -> Void)?
    /// Left arrow — collapse the selected row's section, or step out to its header.
    var onMoveLeft: (() -> Void)?
    /// Right arrow — expand the selected header, or step into its first row.
    var onMoveRight: (() -> Void)?
    /// Tab or Escape — hand keyboard focus back to the active file pane without activating anything.
    var onReturnToPane: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let isHeader = row >= 0 && (delegate?.tableView?(self, isGroupRow: row) ?? false)
        if isHeader {
            onHeaderClick?(row)
            return
        }
        guard row >= 0 else {
            onEmptyClick?()
            return
        }
        super.mouseDown(with: event)
    }

    /// The file-manager keys the focused source list claims; everything else (arrows, type-select)
    /// falls through to `NSTableView`. Left/Right are no-ops for a single-column table by default,
    /// so claiming them for fold/step costs nothing.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            onActivateSelection?()
        case 48: // Tab — back to the pane, not the next key view
            onReturnToPane?()
        case 123: // Left
            onMoveLeft?()
        case 124: // Right
            onMoveRight?()
        default:
            super.keyDown(with: event)
        }
    }

    /// Escape reaches AppKit as `cancelOperation:`, not a `keyDown` we can switch on — it leaves the
    /// sidebar for the active pane, the same exit Tab makes. (Synthetic Escape isn't delivered under
    /// computer-use, so this path is verified with a physical key press — see docs/NOTES.md.)
    override func cancelOperation(_ sender: Any?) {
        onReturnToPane?()
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
