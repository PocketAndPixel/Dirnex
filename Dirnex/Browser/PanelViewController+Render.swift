import AppKit
import DirnexCore

/// Painting a file pane: the two render passes (a navigation's full reload and a live refresh's
/// re-anchor), the rename guard that keeps a background refresh from tearing out the field editor,
/// and the two halves of the cursor⇄selection mirror.
///
/// Split out of `PanelViewController` proper, which is at its 500-line limit, and along the same
/// seam every other concern in this pane already follows (`+Table`, `+Tabs`, `+Sizing`). Everything
/// here is internal rather than private *because* of the split — a cross-file extension does not
/// share the type's private scope, unlike a same-file one — and every one of these already had to
/// be internal for the background-refresh sites in the other extensions to call it.
extension PanelViewController {
    func reloadEverything() {
        // Before `reloadData`, which asks for the bars row by row: the projection has to describe
        // the row set about to be drawn, not the one that was.
        rebuildSizeVisualization()
        tableView.reloadData()
        syncCursorToTable()
        updateChrome()
    }

    /// Re-render after a live FSEvents refresh. Unlike a navigation, this must not yank
    /// the view: the cursor is re-applied but not scrolled to, so a background change
    /// leaves the user's scroll position (and reading spot) where it was. Internal so a
    /// tab switch can re-render the newly active tab without disturbing its scroll.
    func renderRefresh() {
        rebuildSizeVisualization()
        tableView.reloadData()
        syncCursorToTable(scroll: false)
        updateChrome()
        refreshQuickLookIfVisible()
    }

    /// Guard a *live background* refresh (FSEvents, a directory-size total) against running
    /// while an inline rename field is open: a `reloadData` there tears the shared field
    /// editor out of its cell and — because `NSTableView` recycles cell views — leaves it
    /// stranded on the `..` row, silently dropping the rename. When editing is in progress
    /// the caller must skip its refresh (this returns `true`) and note that one is owed, so
    /// the end-editing handler can replay it and the pane still catches up on the change.
    func deferRefreshIfRenaming() -> Bool {
        guard renamingEntryID != nil else { return false }
        renamePendingRefresh = true
        return true
    }

    /// Mirror the table's live selection into the model cursor (the view→model half of
    /// the cursor mirror), reporting whether a real row was selected. Runs both from the
    /// user's own selection change and — crucially — just before a background refresh
    /// re-anchors the cursor.
    ///
    /// `NSTableView` posts its selection-changed notification on a later runloop pass, so
    /// there is a brief window after the user clicks or arrows to a new row where the
    /// table already shows it but `panel.cursor` still points at the row they left. A
    /// live FSEvents refresh, a directory-size completion, or a tab-activation re-list
    /// landing in that window would otherwise anchor on the stale cursor and snap the
    /// visible selection back to the previous file. Reconciling first makes the user's
    /// current selection the anchor, so the refresh preserves it. Internal so the
    /// background-refresh sites in the Tabs and Sizing extensions can call it.
    @discardableResult
    func reconcileCursorFromTable() -> Bool {
        let row = tableView.selectedRow
        guard row >= 0 else { return false }
        cursorOnParentRow = isParentRow(row)
        if let index = entryIndex(forRow: row) {
            panel.moveCursor(to: index)
        }
        return true
    }

    /// Push the cursor into the table's selection (the visible cursor). Navigation
    /// scrolls the cursor into view; a live refresh (`scroll: false`) does not. The
    /// `..` position is honored via `cursorOnParentRow` so a refresh doesn't bump the
    /// user off it, and an empty directory parks the cursor on `..` when one exists.
    /// Internal so the table-input callbacks in `PanelViewController+TableInput` can
    /// re-apply the cursor after marking a row.
    func syncCursorToTable(scroll: Bool = true) {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        let targetRow: Int
        if cursorOnParentRow, parentRowCount == 1 {
            targetRow = 0
        } else if panel.isEmpty {
            targetRow = parentRowCount == 1 ? 0 : -1
        } else {
            targetRow = row(forEntryIndex: panel.cursor)
        }
        // Keep the flag consistent with where the selection actually landed — e.g. a
        // filter that hides every entry parks the cursor on `..`, and Enter must then
        // go up rather than treating a nonexistent entry as the target.
        cursorOnParentRow = targetRow == 0 && parentRowCount == 1
        guard targetRow >= 0 else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        if scroll {
            tableView.scrollRowToVisible(targetRow)
        }
    }
}
