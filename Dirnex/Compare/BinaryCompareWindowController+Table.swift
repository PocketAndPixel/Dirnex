import AppKit
import DirnexCore

/// The byte view's table (PLAN.md §M37 Slice 2): one row of sixteen bytes per table row, offset, left
/// and right in three columns, each cell asking `BinaryRowSource` for its row as it draws.
extension BinaryCompareWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: BinaryHexCell.identifier, owner: nil) as? BinaryHexCell
            ?? BinaryHexCell()
        cell.identifier = BinaryHexCell.identifier
        cell.content = content(column: tableColumn, row: row)
        return cell
    }

    /// What the cell at `row` shows in `column`.
    func content(column: NSTableColumn?, row: Int) -> BinaryHexCell.Content {
        switch column {
        case offsetColumn:
            let offset = BinaryHexLayout.offset(ofRow: Int64(row))
            return .offset(BinaryHexLayout.offsetText(offset, digits: offsetDigits))
        case leftColumn:
            return .side(rows.row(Int64(row)), .left)
        case rightColumn:
            return .side(rows.row(Int64(row)), .right)
        default:
            return .none
        }
    }

    /// Moving the row by hand leaves no change current, and the next one is found from the row.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isMovingSelection else { return }
        currentChangeOffset = nil
        refreshCounter()
    }

    // MARK: - Pages

    /// Have rows reach the table when their page arrives, and read only pages still on screen.
    func connectRows() {
        rows.pagesOnScreen = { [weak self] in self?.pagesOnScreen() ?? [] }
        rows.onLoad = { [weak self] _ in self?.fillBlankRows() }
        rows.onFailure = { [weak self] error in
            self?.readFailure = error
            self?.showBanner()
        }
    }

    /// The pages holding the rows on screen. Nothing yet in a window that has not laid out, whose
    /// first draw then asks again.
    func pagesOnScreen() -> Set<Int64> {
        guard let visible = visibleRows else { return [] }
        let first = BinaryPage.index(ofRow: Int64(visible.lowerBound))
        let last = BinaryPage.index(ofRow: Int64(visible.upperBound))
        return Set(first...last)
    }

    /// The rows at least partly on screen.
    var visibleRows: ClosedRange<Int>? {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return nil }
        return range.location...(range.location + range.length - 1)
    }

    var firstVisibleRow: Int {
        visibleRows?.lowerBound ?? 0
    }

    /// Fill in the rows on screen that were drawn before their page was read, asking for any page
    /// still missing. Run when a page arrives, and on every scroll: the table prepares rows just off
    /// screen, and one whose page was dropped as off screen comes into view with no new draw of its
    /// own to ask again.
    func fillBlankRows() {
        guard let visible = visibleRows else { return }
        let sides = [leftColumn, rightColumn]
        let columns = sides.map { table.column(withIdentifier: $0.identifier) }
        for row in visible {
            for (column, tableColumn) in zip(columns, sides) {
                guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? BinaryHexCell,
                      case .side(.none, _) = cell.content else { continue }
                cell.content = content(column: tableColumn, row: row)
            }
        }
    }

    /// Keep the overview strip on what is on screen.
    @objc func tableDidScroll(_ notification: Notification) {
        overview.visibleRows = visibleRows
        overview.needsDisplay = true
        fillBlankRows()
    }
}
