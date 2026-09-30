import AppKit
import DirnexCore

/// The table's columns: one per column of the file after the row numbers, each as wide as its title
/// and a sample of its values call for (split out of `QuickViewTableView` when the filter's state took
/// the class past SwiftLint's body ceiling).
extension QuickViewTableView {
    /// How many values in all a table measures to size its columns, spread over its columns — about
    /// a hundred rows of a typical file, and fewer rows of a very wide one.
    private static let measurementBudget = 2000

    func rebuildColumns(for table: DelimitedTable?) {
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }
        baseWidths = [:]
        guard let table else { return }
        let rowNumbers = NSTableColumn(identifier: Self.rowNumberColumn)
        rowNumbers.title = "#"
        rowNumbers.headerCell.alignment = .right
        applyHeaderTitle(to: rowNumbers)
        rowNumbers.resizingMask = []
        // Sorting by the row number is the way back to the file's order.
        rowNumbers.sortDescriptorPrototype = NSSortDescriptor(
            key: Self.rowNumberColumn.rawValue,
            ascending: true
        )
        tableView.addTableColumn(rowNumbers)
        let numbers = ceil(
            ("\(max(table.rowCount, 1))" as NSString)
                .size(withAttributes: [.font: Self.rowNumberFont]).width
        ) + 16
        rowNumbers.width = max(numbers, headerWidth(of: rowNumbers))
        rowNumbers.minWidth = Self.minimumRowNumberWidth
        baseWidths[rowNumbers.identifier] = rowNumbers.width

        let sampledRows = min(
            table.rowCount,
            max(8, Self.measurementBudget / max(table.columnCount, 1))
        )
        for index in 0..<table.columnCount {
            let title = table.title(ofColumn: index)
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = title
            column.headerToolTip = title
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
            if table.numericColumns.indices.contains(index), table.numericColumns[index] {
                column.headerCell.alignment = .right
            }
            applyHeaderTitle(to: column)
            column.maxWidth = 10000
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
            column.minWidth = Self.minimumColumnWidth
            column.width = width(ofColumn: column, index: index, in: table, sampling: sampledRows)
            baseWidths[column.identifier] = column.width
        }
    }

    /// Wide enough for the header and the widest sampled value, within the two bounds. A value is
    /// measured by its first 80 characters, which is already past the widest column allowed. A column
    /// of numbers is wide enough for its longest value in the whole file, since a sort can bring any
    /// of them to the top and a number cut off with an ellipsis reads as a different number.
    private func width(
        ofColumn column: NSTableColumn,
        index: Int,
        in table: DelimitedTable,
        sampling rows: Int
    ) -> CGFloat {
        var widest = headerWidth(of: column)
        for row in 0..<rows {
            let value = String(table.cell(row: row, column: index).prefix(80))
            guard !value.isEmpty else { continue }
            let measured = (value as NSString).size(withAttributes: [.font: Self.cellFont]).width
            widest = max(widest, ceil(measured) + 14)
        }
        if table.numericColumns.indices.contains(index), table.numericColumns[index] {
            let digit = ("0" as NSString).size(withAttributes: [.font: Self.cellFont]).width
            let longest = CGFloat(table.longestValueByteCount(inColumn: index))
            widest = max(widest, ceil(longest * digit) + 14)
        }
        return min(max(widest, Self.minimumColumnWidth), Self.maximumColumnWidth)
    }

    /// A header's width with a sort arrow in it: its title at the current level's size, and the
    /// arrow's and the cell's own room, which do not scale (`headerChrome`).
    func headerWidth(of column: NSTableColumn) -> CGFloat {
        titleWidth(of: column) + Self.headerChrome
    }

    /// How much wider than its title a header has to be to show it whole beside a sort arrow: the
    /// cell's padding around the title, the arrow's room at the right edge, and a gap between the two.
    ///
    /// The first two are AppKit's, measured once from a header cell: `cellSize` less the title's own
    /// width (4 pt), and the header's right edge less `sortIndicatorRect`'s left one (a 9 pt arrow
    /// drawn 8 pt in, so 17). Neither `sizeToFit` answer is usable: with an attributed title — which
    /// the zoom needs — it leaves the arrow out altogether (4 pt of room), and a plain title's 21 pt
    /// still cut a sorted `elapsed` to `elaps…` at 0.8 (seen live), which is the gap.
    static let headerChrome: CGFloat = {
        let cell = NSTableHeaderCell(textCell: "")
        cell.attributedStringValue = NSAttributedString(
            string: "value",
            attributes: [.font: baseHeaderFont]
        )
        let title = ("value" as NSString).size(withAttributes: [.font: baseHeaderFont]).width
        let padding = max(cell.cellSize.width - title, 0)
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 28)
        let arrow = bounds.maxX - cell.sortIndicatorRect(forBounds: bounds).minX
        return ceil(padding + arrow + headerTitleGap)
    }()

    /// The room between a header's title and its sort arrow.
    static let headerTitleGap: CGFloat = 8

    /// The width of a column's title in the header font at the current level.
    func titleWidth(of column: NSTableColumn) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Self.baseHeaderFont.pointSize * CGFloat(zoomLevel))
        return ceil((column.title as NSString).size(withAttributes: [.font: font]).width)
    }
}
