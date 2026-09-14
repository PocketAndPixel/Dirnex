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
/// The rows are never moved: the table keeps its parse and a permutation over it (`rowOrder`), which
/// is what lets a row keep its number from the file and lets a sort be undone for free.
extension QuickViewTableView {
    /// The data row shown at `row`.
    func record(atDisplayedRow row: Int) -> Int {
        guard let rowOrder, rowOrder.indices.contains(row) else { return row }
        return rowOrder[row]
    }

    /// Where data row `record` is shown.
    func displayedRow(ofRecord record: Int) -> Int {
        guard let rowPositions, rowPositions.indices.contains(record) else { return record }
        return rowPositions[record]
    }

    /// Back to the file's order with no column marked, for a new table — without running a sort for
    /// the cleared indicators, and discarding a sort still running for the old one.
    ///
    /// Clearing the indicators here is not what empties them: AppKit does that by itself when the
    /// sorted column is removed, and calls the delegate as it does (measured). Doing it first, under
    /// `isResettingSort`, is what keeps that call from running a sort in the middle of a rebuild.
    func resetSort() {
        sortGeneration += 1
        rowOrder = nil
        rowPositions = nil
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
    ///
    /// Where the view lands depends on whose the selection is. The row selected as the table opened
    /// is nobody's choice, so a sort goes to the top of the new order and selects what is there —
    /// sorting by size to see the largest shows the largest. Rows somebody selected stay selected,
    /// and the view follows the first of them.
    private func apply(_ order: [Int]?) {
        let chosen = selectionIsAutomatic
            ? []
            : tableView.selectedRowIndexes.map { record(atDisplayedRow: $0) }
        rowOrder = order
        rowPositions = order.map { order in
            var positions = [Int](repeating: 0, count: order.count)
            for (position, record) in order.enumerated() {
                positions[record] = position
            }
            return positions
        }
        tableView.reloadData()
        guard tableView.numberOfRows > 0 else {
            showSelectedRecord()
            return
        }
        let rows = chosen.isEmpty
            ? IndexSet(integer: 0)
            : IndexSet(chosen.map { displayedRow(ofRecord: $0) })
        selectProgrammatically(rows)
        tableView.scrollRowToVisible(rows.first ?? 0)
        showSelectedRecord()
    }

    /// Select `rows` without it counting as somebody's choice.
    func selectProgrammatically(_ rows: IndexSet) {
        isSelectingProgrammatically = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isSelectingProgrammatically = false
    }
}
