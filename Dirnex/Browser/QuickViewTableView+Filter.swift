import AppKit
import DirnexCore

/// Narrowing Quick View's table to the rows containing some text (2026-09-15).
///
/// View ▸ Filter Table (⌥⌘F) shows a bar over the table with the keyboard in its text; typing narrows
/// the rows as it goes, in every column or in the one the picker names. Which rows match is
/// `DirnexCore`'s (`DelimitedTable.rowsMatching`): the text anywhere in a cell, ignoring case, the
/// pane's own filter's rule. It runs off the main actor, since text outside ASCII decodes every cell
/// it reads (220 ms for 173 000 rows of three columns, release) and the table must go on scrolling;
/// the rows on screen stay until the new ones land.
///
/// It is a narrowing of the same rows the sort orders (`DelimitedTableRows`), so each keeps its
/// number from the file and its place in the sort, and clearing the text gives back exactly the table
/// that was there. A new file opens with the bar put away and nothing filtered: its columns are not
/// this file's, and rows hidden by a filter nobody can see read as a broken preview.
///
/// The keys, while the keyboard is in the text:
/// - **Esc** clears the text, and a second Esc puts the bar away. The window's Quick View monitor
///   leaves Esc to any field being typed in, so the third, back in the file list, closes Quick View.
/// - **↑ / ↓** step through the rows the filter left, the strip following. The file list's arrows
///   are its own again once the keyboard goes back to it.
/// - **Return** and **Tab** hand the keyboard back to the file list and keep the filter.
extension QuickViewTableView {
    /// Show the bar if it is not up, with the keyboard in its text and the text selected, so typing
    /// replaces it. Does nothing with no table on screen.
    func beginFiltering() {
        guard table != nil else { return }
        setFilterBarShown(true)
        window?.makeFirstResponder(filterBar.field)
        filterBar.field.currentEditor()?.selectAll(nil)
    }

    /// Put the bar away with every row back, and hand the keyboard back if it was in the bar.
    func endFiltering() {
        let hadKeyboard = filterHasKeyboard
        filterBar.field.stringValue = ""
        filterChanged()
        setFilterBarShown(false)
        if hadKeyboard { giveKeyboardBack() }
    }

    /// Whether the keyboard is in the filter's text: its field editor is first responder.
    var filterHasKeyboard: Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor else {
            return false
        }
        return (editor.delegate as? NSView) === filterBar.field
    }

    /// Run the filter the bar now describes. An empty text clears it at once; anything else is read
    /// off the main actor, and a filter still running for older text is stopped.
    func filterChanged() {
        filterGeneration += 1
        filterCancellation?.isCancelled = true
        filterCancellation = nil
        let query = filterBar.query
        guard let table, !query.isEmpty else {
            filterTask = nil
            applyFilter(nil)
            return
        }
        let generation = filterGeneration
        let column = filterBar.column
        let cancellation = CancellationFlag()
        filterCancellation = cancellation
        filterTask = Task { [weak self] in
            let matches = await BlockingWork.run {
                table.rowsMatching(query, inColumn: column) { cancellation.isCancelled }
            }
            guard let self, generation == filterGeneration, let matches else { return }
            applyFilter(matches)
        }
    }

    /// What a key the field editor was about to act on does instead (see the type's own comment).
    func filterCommand(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.cancelOperation(_:)):
            if filterBar.query.isEmpty {
                endFiltering()
            } else {
                filterBar.field.stringValue = ""
                filterChanged()
            }
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            giveKeyboardBack()
        case #selector(NSResponder.moveUp(_:)):
            stepSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            stepSelection(by: 1)
        default:
            return false
        }
        return true
    }

    /// No filter, the bar away, and the keyboard back if it was in the bar — for a new table, which
    /// must not run a filter for the old one's text, and must not keep one still running.
    func resetFilter() {
        filterGeneration += 1
        filterCancellation?.isCancelled = true
        filterCancellation = nil
        filterTask = nil
        filterMatches = nil
        let hadKeyboard = filterHasKeyboard
        filterBar.field.stringValue = ""
        filterBar.showCount(shown: 0, of: 0, filtering: false)
        setFilterBarShown(false)
        if hadKeyboard { giveKeyboardBack() }
    }

    /// The height the table and the strip share: the surface's, less the bar's while it is shown.
    var roomBelowFilterBar: CGFloat {
        bounds.height - (filterBar.isHidden ? 0 : QuickViewTableFilterBar.height)
    }

    func installFilterBar() {
        filterBar.isHidden = true
        addSubview(filterBar)
        let underBar = scrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor)
        tableTopToFilterBar = underBar
        NSLayoutConstraint.activate([
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterBar.topAnchor.constraint(equalTo: topAnchor)
        ])
        filterBar.changed = { [weak self] in self?.filterChanged() }
        filterBar.command = { [weak self] command in self?.filterCommand(command) ?? false }
        filterBar.close = { [weak self] in self?.endFiltering() }
    }

    // MARK: - Private

    private func applyFilter(_ matches: [Bool]?) {
        filterMatches = matches
        reloadRows()
        filterBar.showCount(
            shown: rows.count,
            of: table?.rowCount ?? 0,
            filtering: matches != nil
        )
    }

    private func setFilterBarShown(_ shown: Bool) {
        guard filterBar.isHidden == shown else { return }
        filterBar.isHidden = !shown
        // One off before the other on, so the scroll view is never pinned to both edges at once.
        if shown {
            tableTopToSurface?.isActive = false
            tableTopToFilterBar?.isActive = true
        } else {
            tableTopToFilterBar?.isActive = false
            tableTopToSurface?.isActive = true
        }
        needsLayout = true
    }

    /// Back to the file list, or — with nobody to say where that is — to the table, whose arrows the
    /// window's monitor hands on to the list in any case.
    private func giveKeyboardBack() {
        if let returnKeyboard {
            returnKeyboard()
        } else {
            window?.makeFirstResponder(tableView)
        }
    }

    /// Select the row `step` rows from the selection, within the rows drawn: from the last selected
    /// going down, the first going up, and from the top or the bottom when nothing is selected.
    private func stepSelection(by step: Int) {
        guard !rows.isEmpty else { return }
        let selected = tableView.selectedRowIndexes
        let from = step > 0 ? selected.last : selected.first
        let target = from.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
        let row = min(max(target, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }
}
