import AppKit
import DirnexCore

/// Narrowing Quick View's table to the rows containing some text (2026-09-15).
///
/// View ▸ Filter (⌥⌘F) shows a bar over the table with the keyboard in its text; typing narrows the
/// rows as it goes, in every column or in the one the picker names. Which rows match is `DirnexCore`'s
/// (`DelimitedTable.rowsMatching`): the text anywhere in a cell, ignoring case, the pane's own filter's
/// rule. It runs off the main actor, since text outside ASCII decodes every cell it reads (220 ms for
/// 173 000 rows of three columns, release) and the table must go on scrolling; the rows on screen stay
/// until the new ones land.
///
/// It is a narrowing of the same rows the sort orders (`DelimitedTableRows`), so each keeps its
/// number from the file and its place in the sort, and clearing the text gives back exactly the table
/// that was there. A new file opens with the bar put away and nothing filtered: its columns are not
/// this file's, and rows hidden by a filter nobody can see read as a broken preview.
///
/// What the bar's keys do — Esc, Return, Tab, ↑ and ↓ — is `QuickViewFilterHost`'s, which the JSON
/// tree shares.
extension QuickViewTableView: QuickViewFilterHost {
    var filteredRowsView: NSTableView { tableView }

    var hasFilterableContent: Bool { table != nil }

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
}
