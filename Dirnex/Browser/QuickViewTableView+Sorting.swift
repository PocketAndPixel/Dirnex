import AppKit
import DirnexCore

/// Sorting Quick View's table by a click on a column header (2026-09-15).
///
/// The order is `DirnexCore`'s (`DelimitedTable.rowOrder(sortedByColumn:ascending:)`): numbers by
/// value, text the way Finder sorts names, blanks last. It runs off the main actor, since a column of
/// 173 000 distinct names takes 663 ms (release) and the table must go on scrolling meanwhile; the
/// header's arrow changes at once and the rows follow when the order lands. A second click reverses
/// it, and the `#` column is the way back to the file's order.
///
/// The rows are never moved: the table keeps its parse and a permutation over it (`sortOrder`), which
/// is what lets a row keep its number from the file and lets a sort be undone for free. The filter
/// narrows that same permutation (`QuickViewTableView+Filter`), and `reloadRows` draws the two together.
extension QuickViewTableView {
    /// The data row shown at `row`.
    func record(atDisplayedRow row: Int) -> Int {
        rows.record(atRow: row)
    }

    /// Back to the file's order with no column marked, for a new table — without running a sort for
    /// the cleared indicators, and discarding a sort still running for the old one.
    ///
    /// Clearing the indicators here is not what empties them: AppKit does that by itself when the
    /// sorted column is removed, and calls the delegate as it does (measured). Doing it first, under
    /// `isResettingSort`, is what keeps that call from running a sort in the middle of a rebuild.
    func resetSort() {
        sortGeneration += 1
        sortOrder = nil
        isResettingSort = true
        tableView.sortDescriptors = []
        isResettingSort = false
    }

    /// Sort by the header just clicked.
    func sortDescriptorsChanged() {
        guard !isResettingSort, let table else { return }
        sortGeneration += 1
        let generation = sortGeneration
        guard let descriptor = tableView.sortDescriptors.first else {
            apply(nil)
            return
        }
        if descriptor.key == Self.rowNumberColumn.rawValue {
            apply(descriptor.ascending ? nil : Array((0..<table.rowCount).reversed()))
            return
        }
        guard let key = descriptor.key, let column = Int(key) else { return }
        let ascending = descriptor.ascending
        sortTask = Task { [weak self] in
            let order = await BlockingWork.run {
                table.rowOrder(sortedByColumn: column, ascending: ascending)
            }
            guard let self, generation == sortGeneration else { return }
            apply(order)
        }
    }

    /// Show the rows in `order`, or in the file's order for `nil`.
    private func apply(_ order: [Int]?) {
        sortOrder = order
        reloadRows()
    }

    /// Draw the rows the sort and the filter call for now.
    ///
    /// Where the view lands depends on whose the selection is. The row selected as the table opened
    /// is nobody's choice, so it goes to the top of the new rows and selects what is there — sorting
    /// by size to see the largest shows the largest, and a filter shows its first match. Rows somebody
    /// selected stay selected wherever they are still drawn, and the view follows the first of them.
    /// When the filter leaves out every one of them the top row is selected, as nobody's choice again.
    func reloadRows() {
        let chosen = selectionIsAutomatic
            ? []
            : tableView.selectedRowIndexes.map { record(atDisplayedRow: $0) }
        rows = DelimitedTableRows(
            rowCount: table?.rowCount ?? 0,
            order: sortOrder,
            matches: filterMatches
        )
        tableView.reloadData()
        let kept = IndexSet(chosen.compactMap { rows.row(ofRecord: $0) })
        if kept.isEmpty { selectionIsAutomatic = true }
        let selection = !kept.isEmpty ? kept : !rows.isEmpty ? IndexSet(integer: 0) : IndexSet()
        selectProgrammatically(selection)
        if let first = selection.first {
            tableView.scrollRowToVisible(first)
        }
        showSelectedRecord()
    }

    /// Select `rows` without it counting as somebody's choice.
    func selectProgrammatically(_ rows: IndexSet) {
        isSelectingProgrammatically = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isSelectingProgrammatically = false
    }
}
