import AppKit
import DirnexCore

/// Finder-style mouse selection over the file list — Cmd-click toggles one entry's
/// mark, Shift-click extends a range. It drives the same mark set as the Total
/// Commander keyboard gestures (Space, `+`/`-`, `*`): the marked entries render in the
/// bold accent style and are what operations act on. A plain click never marks — it
/// only moves the cursor (the blue row highlight) and re-anchors the range for a later
/// Shift-click; operations still act on the cursor entry when nothing is marked.
///
/// A Cmd/Shift click is consumed here and never reaches `NSTableView`'s own
/// single-selection/drag machinery; a plain click falls through to `super.mouseDown`
/// so the cursor moves and a drag-out can still begin (see `FileTableView.mouseDown`).
/// The `mouseSelectionAnchor`/`mouseSelectionBase` state for the range sweep lives on
/// `PanelViewController`.
extension PanelViewController {
    func fileTable(
        _ tableView: FileTableView,
        didClickRow row: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)

        // No selection modifier: let the table run its own click (cursor move + drag).
        // A plain click never touches the marks — it only re-anchors the range for a
        // later Shift-click.
        guard command || shift else {
            handlePlainClick(row: row)
            return false
        }

        // A Cmd/Shift click on the `..` row or empty space has nothing to (de)select, but
        // we still consume it so the table doesn't extend its own selection there.
        guard let index = entryIndex(forRow: row) else { return true }

        let previousMarks = panel.selection
        if shift {
            let anchorIndex = resolvedAnchorIndex(fallingBackTo: index)
            panel.selectRange(from: anchorIndex, through: index, base: mouseSelectionBase)
            recordMarkChange(since: previousMarks, label: "Select Range")
        } else {
            panel.toggleMarkMovingCursor(to: index)
            setAnchor(to: index)
            recordMarkChange(since: previousMarks, label: "Mark")
        }
        cursorOnParentRow = false
        reloadEverything()
        refreshQuickLookIfVisible()
        return true
    }

    /// Drop the range anchor — call sites where the marks reset (navigation, Esc-clear)
    /// so a later Shift-click doesn't sweep from a stale, unrelated entry.
    func resetMouseSelectionAnchor() {
        mouseSelectionAnchor = nil
        mouseSelectionBase = []
    }

    // MARK: - Plain click

    /// A plain click leaves the marks untouched (that is what Cmd/Shift are for). It only
    /// re-anchors the range so a following Shift-click sweeps from the just-clicked row;
    /// the cursor itself is moved by the table's own `super.mouseDown`, which runs right
    /// after this returns. Clicking the `..` row or empty space just drops the anchor.
    private func handlePlainClick(row: Int) {
        guard let index = entryIndex(forRow: row) else {
            resetMouseSelectionAnchor()
            return
        }
        setAnchor(to: index)
    }

    // MARK: - Anchor bookkeeping

    private func setAnchor(to index: Int) {
        mouseSelectionAnchor = panel.model[index].id
        mouseSelectionBase = panel.selection
    }

    /// The entry index a Shift-click range extends from. Prefer the live mouse anchor;
    /// when it is missing — the first gesture is a Shift-click, or the marks were made
    /// with the keyboard — fall back to the current cursor and adopt it (plus the marks
    /// already set) as the anchor/base, so the sweep extends from where the user is
    /// without discarding what they had marked.
    private func resolvedAnchorIndex(fallingBackTo index: Int) -> Int {
        if let id = mouseSelectionAnchor, let anchor = panel.model.index(ofID: id) {
            return anchor
        }
        let fallback = cursorOnParentRow
            ? index
            : min(max(panel.cursor, 0), max(panel.count - 1, 0))
        mouseSelectionBase = panel.selection
        mouseSelectionAnchor = panel.isEmpty ? nil : panel.model[fallback].id
        return fallback
    }
}
