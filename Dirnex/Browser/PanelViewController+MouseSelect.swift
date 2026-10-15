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
        // Set again below for the one click that can be the first half of a Cmd-double-click.
        lastCommandClick = nil

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
            recordMarkChange(since: previousMarks, label: .selectRange)
        } else {
            panel.toggleMarkMovingCursor(to: index)
            setAnchor(to: index)
            recordMarkChange(since: previousMarks, label: .mark)
            if let entry = panel.displayedEntry(at: index) {
                lastCommandClick = (entry.id, previousMarks)
            }
        }
        cursorOnParentRow = false
        reloadEverything()
        refreshQuickLookIfVisible()
        return true
    }

    /// The second click of a Cmd-double-click: open the row in the other pane, as Cmd+Return does.
    ///
    /// The first click was an ordinary Cmd-click and toggled the row's mark. The user was opening
    /// the row, not marking it, so the marks go back to what they were and the journal entry that
    /// click made is taken back. Otherwise Cmd+Z would stop on a mark nobody meant to make. Only when
    /// that click was on this row: a Cmd-click made on its own a moment earlier is left alone.
    ///
    /// The `..` row has no mark to put back and nothing to open in another pane, so it goes up, as
    /// a double-click does.
    func fileTable(_ tableView: FileTableView, didCommandDoubleClickRow row: Int) {
        if isParentRow(row) {
            goToParent()
            return
        }
        guard let index = entryIndex(forRow: row),
              let entry = panel.displayedEntry(at: index) else { return }
        if let click = lastCommandClick, click.entry == entry.id,
           host?.withdrawSelectionChange(
               on: self,
               directory: panel.path,
               previousMarks: click.previousMarks,
               label: .mark
           ) == true {
            panel.setSelection(click.previousMarks)
        }
        lastCommandClick = nil
        panel.moveCursor(to: index)
        cursorOnParentRow = false
        reloadEverything()
        openCurrentEntry(inOtherPane: true)
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

    /// `index` is a *display row*, so the entry comes from `panel.displayedEntry(at:)` — in tree
    /// mode the pane draws more rows than the root directory has entries, and reading
    /// `panel.model[index]` there is an out-of-range crash on the first click below the last
    /// root-level row (found live, PLAN.md §M15 Slice 4).
    private func setAnchor(to index: Int) {
        mouseSelectionAnchor = panel.displayedEntry(at: index)?.id
        mouseSelectionBase = panel.selection
    }

    /// The entry index a Shift-click range extends from. Prefer the live mouse anchor;
    /// when it is missing — the first gesture is a Shift-click, or the marks were made
    /// with the keyboard — fall back to the current cursor and adopt it (plus the marks
    /// already set) as the anchor/base, so the sweep extends from where the user is
    /// without discarding what they had marked.
    private func resolvedAnchorIndex(fallingBackTo index: Int) -> Int {
        if let id = mouseSelectionAnchor, let anchor = panel.displayedIndex(ofID: id) {
            return anchor
        }
        let fallback = cursorOnParentRow
            ? index
            : min(max(panel.cursor, 0), max(panel.count - 1, 0))
        mouseSelectionBase = panel.selection
        mouseSelectionAnchor = panel.displayedEntry(at: fallback)?.id
        return fallback
    }
}
