import AppKit
import DirnexCore
import Quartz

/// The pane's `FileTableView` input callbacks — every key/gesture the table forwards
/// (open, go-up, backspace, type-to-filter, mark, invert, Quick Look, edit-path, focus).
/// Split out of `PanelViewController` proper to keep that file under the length limit; the
/// two rendering helpers these callbacks lean on (`redrawRow`, `setFilter`) live here too,
/// since nothing else uses them.
extension PanelViewController: FileTableViewInput {
    func fileTableOpenSelection(_ tableView: FileTableView) {
        if cursorOnParentRow {
            goToParent()
        } else {
            openCurrentEntry()
        }
    }

    func fileTableGoToParent(_ tableView: FileTableView) {
        goToParent()
    }

    func fileTable(_ tableView: FileTableView, menuForRow row: Int) -> NSMenu? {
        contextMenu(forRow: row)
    }

    func fileTableBackspace(_ tableView: FileTableView) {
        if panel.model.filter.isEmpty {
            goToParent()
        } else {
            setFilter(String(panel.model.filter.dropLast()))
        }
    }

    func fileTableCancel(_ tableView: FileTableView) {
        if !panel.model.filter.isEmpty {
            setFilter("")
        } else if host?.isQuickViewEnabled == true {
            // Esc backs out of Quick View before touching the marks — it's a distinct mode the
            // user stepped into, and the preview is the obvious thing to dismiss. It closes
            // straight out to the file list from any of the three sizes rather than stepping down
            // to a smaller one, which would make Esc a mode changer instead of an exit.
            host?.closeQuickView()
        } else if panel.selectionCount > 0 {
            let previousMarks = panel.selection
            panel.clearSelection()
            recordMarkChange(since: previousMarks, label: .clearSelection)
            resetMouseSelectionAnchor()
            tableView.reloadData()
            updateChrome()
            refreshQuickLookIfVisible()
        }
    }

    func fileTable(_ tableView: FileTableView, didType text: String) {
        setFilter(panel.model.filter + text)
    }

    func fileTableToggleMarkAndAdvance(_ tableView: FileTableView) {
        guard !panel.isEmpty else { return }
        // Space on `..` marks nothing (it isn't a real entry) — just step onto the
        // first entry, matching the "advance" half of the gesture.
        if cursorOnParentRow {
            tableView.selectRowIndexes(
                IndexSet(integer: parentRowCount),
                byExtendingSelection: false
            )
            tableView.scrollRowToVisible(parentRowCount)
            return
        }
        // Capture the entry under the cursor before we advance past it: Space on a
        // directory also computes its size in place (TC), applied when the walk lands.
        let sizedDirectory = panel.currentEntry.flatMap { $0.isDirectoryLike ? $0 : nil }
        let markedRow = row(forEntryIndex: panel.cursor)
        let previousMarks = panel.selection
        panel.toggleMarkAtCursorAndAdvance()
        recordMarkChange(since: previousMarks, label: .mark)
        redrawRow(markedRow)
        syncCursorToTable()
        updateChrome()
        refreshQuickLookIfVisible()
        if let sizedDirectory {
            computeDirectorySize(for: sizedDirectory)
        }
    }

    func fileTableSwitchPanel(_ tableView: FileTableView) {
        host?.panelRequestsFocusSwitch(self)
    }

    func fileTableMarkAll(_ tableView: FileTableView) {
        let previousMarks = panel.selection
        panel.selectAll()
        recordMarkChange(since: previousMarks, label: .selectAll)
        tableView.reloadData()
        updateChrome()
        refreshQuickLookIfVisible()
    }

    func fileTableInvertMarks(_ tableView: FileTableView) {
        invertMarks()
    }

    func fileTableToggleQuickLook(_ tableView: FileTableView) {
        guard let previewPanel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), previewPanel.isVisible {
            previewPanel.orderOut(nil)
        } else {
            previewPanel.makeKeyAndOrderFront(nil)
            // Opening on an archive member: it has no on-disk file yet, so extract it on demand
            // and reload the panel once it lands. A no-op for a local file or empty selection.
            prepareArchivePreview { [weak self] in self?.refreshQuickLookIfVisible() }
        }
    }

    func fileTableMinimumCursorRow(_ tableView: FileTableView) -> Int {
        host?.quickViewMode.isFullSize == true ? parentRowCount : 0
    }

    func fileTable(_ tableView: FileTableView, stepQuickViewCursorBy delta: Int) -> Bool {
        guard host?.quickViewMode.isFullSize == true else { return false }
        // Through the window, not `stepCursor` directly: the preview it owns turns the page for the
        // step, so the keys flip like the gesture instead of swapping the file in place.
        // Consumed either way — a ← on the first file is the end of the list, not an arrow key the
        // table should get a second go at.
        host?.flipQuickView(steps: delta)
        return true
    }

    func fileTableEditPath(_ tableView: FileTableView) {
        // Editing a virtual results path as text makes no sense — base the field at Home so a
        // typed path navigates out of the results into a real directory. Same rule the bar's own
        // double-click uses, so the two ways in agree (iCloud Drive bases at its real container).
        let base = PathBarView.editBase(for: panel.path) ?? VFSPath.local(NSHomeDirectory())
        pathBar.beginEditing(base: base)
    }

    func fileTableDidBecomeFirstResponder(_ tableView: FileTableView) {
        host?.panelDidBecomeActive(self)
    }
}

// MARK: - Rendering helpers

private extension PanelViewController {
    func redrawRow(_ row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        let columns = IndexSet(integersIn: 0..<tableView.numberOfColumns)
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: columns)
    }

    /// Replace the type-to-filter and re-render. `Panel`/`DirectoryModel` re-anchor the
    /// cursor by identity across the change, so the cursor stays on the same file when
    /// it survives the narrowing.
    func setFilter(_ text: String) {
        panel.setFilter(text)
        reloadEverything()
        refreshQuickLookIfVisible()
    }
}
