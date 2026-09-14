import AppKit
import DirnexCore

/// A delimited-text file as rows and columns, with the selected row's full values underneath — one
/// of `QuickViewPreviewView`'s backends (`QuickViewPreviewView+Table`).
///
/// Three parts, stacked: the table, which scrolls both ways and cuts a long value off at its column's
/// edge; the strip, which shows every value of the selected row wrapped and selectable, since a
/// column wide enough for the longest cell would be a column wider than the screen; and the notice a
/// file past the read limit carries. The first data row is selected as a file opens, so the strip
/// says something before anything is clicked — the arrows belong to the file list, not to this.
@MainActor
final class QuickViewTableView: NSView {
    let scrollView = NSScrollView()
    let tableView = QuickViewDataTableView()
    let strip = QuickViewRecordStrip()
    private let truncationNotice = NSVisualEffectView()
    private var stripHeight: NSLayoutConstraint?

    /// The table on screen, or `nil` once cleared.
    private(set) var table: DelimitedTable?

    // The sort's state, kept here because an extension cannot hold any
    // (`QuickViewTableView+Sorting` owns every rule about it).

    /// The data row shown at each position, or `nil` while the rows are in the file's order.
    var rowOrder: [Int]?
    /// The inverse of `rowOrder`: where each data row is shown.
    var rowPositions: [Int]?
    /// Bumped by every sort and every new table, so a sort landing after either is discarded.
    var sortGeneration = 0
    /// The last sort sent off the main actor — what a test awaits to know it has landed, or been
    /// discarded, rather than guessing how long that takes.
    var sortTask: Task<Void, Never>?
    /// Set while the sort indicators are cleared for a new table, which is not a sort to run.
    var isResettingSort = false
    /// Whether the selection is still the one the table opened with rather than one somebody made —
    /// which decides where a sort leaves the view.
    var selectionIsAutomatic = true
    var isSelectingProgrammatically = false

    /// The data font, and what a column is measured in: the system font with fixed-width digits, so
    /// a column of numbers lines up the way it does in Numbers and Activity Monitor.
    static let cellFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize,
        weight: .regular
    )
    static let rowNumberFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    )
    /// A column is never narrower than this, and grows to fit its title and sampled values up to
    /// `maximumColumnWidth`, past which a value is cut off with an ellipsis and read in the strip.
    static let minimumColumnWidth: CGFloat = 44
    static let maximumColumnWidth: CGFloat = 320
    static let rowNumberColumn = NSUserInterfaceItemIdentifier("row")
    /// How many values in all a table measures to size its columns, spread over its columns — about
    /// a hundred rows of a typical file, and fewer rows of a very wide one.
    private static let measurementBudget = 2000

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildTable()
        buildStrip()
        buildNotice()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// Show `table`, back at its top-left with its first row selected.
    func show(_ table: DelimitedTable, isTruncated: Bool) {
        resetSort()
        self.table = table
        rebuildColumns(for: table)
        tableView.reloadData()
        // To the first row and column, not to the document's origin. The column header floats over
        // the rows, so the scroll view rests *above* the origin by the header's height (plus the title
        // bar's, in a full-size window), and `scroll(.zero)` put row 1 under the header — found live.
        selectionIsAutomatic = true
        if table.rowCount > 0 {
            tableView.scrollRowToVisible(0)
            selectProgrammatically(IndexSet(integer: 0))
        }
        if table.columnCount > 0 {
            tableView.scrollColumnToVisible(0)
        }
        showSelectedRecord()
        truncationNotice.isHidden = !isTruncated
        needsLayout = true
    }

    func clearTable() {
        resetSort()
        table = nil
        rebuildColumns(for: nil)
        tableView.reloadData()
        strip.clear()
        truncationNotice.isHidden = true
    }

    /// Whether the table is wider than the surface, so a sideways two-finger scroll pans it rather
    /// than turning to the next file — Preview's rule, which the image and PDF backends follow too.
    var pansHorizontally: Bool {
        guard let document = scrollView.documentView else { return false }
        return document.frame.width > scrollView.contentView.bounds.width + 0.5
    }

    /// The selected row's values in the strip — the last row selected, when several are.
    func showSelectedRecord() {
        guard let table, tableView.selectedRow >= 0, tableView.selectedRow < table.rowCount else {
            strip.clear()
            needsLayout = true
            return
        }
        let row = record(atDisplayedRow: tableView.selectedRow)
        strip.show((0..<table.columnCount).map { column in
            (table.title(ofColumn: column), table.cell(row: row, column: column))
        })
        needsLayout = true
    }

    // MARK: - Columns

    private func rebuildColumns(for table: DelimitedTable?) {
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }
        guard let table else { return }
        let rowNumbers = NSTableColumn(identifier: Self.rowNumberColumn)
        rowNumbers.title = "#"
        rowNumbers.headerCell.alignment = .right
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
            column.minWidth = Self.minimumColumnWidth
            column.maxWidth = 10000
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
            column.width = width(ofColumn: column, index: index, in: table, sampling: sampledRows)
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

    /// The header's own width with a sort arrow in it — AppKit's arithmetic, asked of the header cell
    /// rather than guessed, so a sorted column's title is not cut short by its own arrow.
    private func headerWidth(of column: NSTableColumn) -> CGFloat {
        tableView.setIndicatorImage(NSImage(named: "NSAscendingSortIndicator"), in: column)
        column.sizeToFit()
        tableView.setIndicatorImage(nil, in: column)
        return ceil(column.width)
    }

    // MARK: - Layout

    /// The strip takes what its text needs, up to two fifths of the surface, and scrolls past that.
    override func layout() {
        let wanted = strip.isEmpty ? 0 : strip.fittingHeight(forWidth: bounds.width)
        let height = min(wanted, max(bounds.height * 0.4, 48))
        if let stripHeight, abs(stripHeight.constant - height) > 0.5 {
            stripHeight.constant = height
        }
        super.layout()
    }

    private func buildTable() {
        tableView.style = .plain
        tableView.font = Self.cellFont
        tableView.rowHeight = ceil(Self.cellFont.ascender - Self.cellFont.descender) + 6
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.copiedText = { [weak self] rows in
            guard let self else { return nil }
            return table?.tabSeparatedText(rows: rows.map(record(atDisplayedRow:)))
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        addSubview(scrollView)
    }

    private func buildStrip() {
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        let height = strip.heightAnchor.constraint(equalToConstant: 0)
        stripHeight = height
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: strip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            height
        ])
    }

    /// The same "first 4 MB" notice the text view floats, over the bottom of the table.
    private func buildNotice() {
        truncationNotice.material = .hudWindow
        truncationNotice.blendingMode = .withinWindow
        truncationNotice.state = .active
        truncationNotice.wantsLayer = true
        truncationNotice.layer?.cornerRadius = 6
        truncationNotice.isHidden = true
        truncationNotice.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: QuickViewTextView.truncationText)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        truncationNotice.addSubview(label)
        addSubview(truncationNotice)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: truncationNotice.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: truncationNotice.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: truncationNotice.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: truncationNotice.bottomAnchor, constant: -5),
            truncationNotice.centerXAnchor.constraint(equalTo: centerXAnchor),
            truncationNotice.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -12)
        ])
    }
}

// MARK: - Rows and cells

extension QuickViewTableView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        table?.rowCount ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let table, let tableColumn else { return nil }
        let cell = tableView.makeView(withIdentifier: QuickViewTableCell.identifier, owner: nil)
            as? QuickViewTableCell ?? QuickViewTableCell()
        // A sorted table draws its rows from where the sort put them, and numbers each by its place
        // in the file, so a row keeps its number whichever column it was sorted by.
        let record = record(atDisplayedRow: row)
        if tableColumn.identifier == Self.rowNumberColumn {
            cell.show(
                "\(record + 1)",
                font: Self.rowNumberFont,
                color: .secondaryLabelColor,
                alignment: .right
            )
            return cell
        }
        guard let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let isNumeric = table.numericColumns.indices.contains(column) && table.numericColumns[column]
        cell.show(
            table.cell(row: record, column: column),
            font: Self.cellFont,
            color: .labelColor,
            alignment: isNumeric ? .right : .left
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !isSelectingProgrammatically { selectionIsAutomatic = false }
        showSelectedRecord()
    }

    /// A click on a column header: sort by it, or reverse the sort it already has.
    func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        sortDescriptorsChanged()
    }
}

/// One cell: a single-line label, centered vertically, cut off with an ellipsis, and floating its
/// whole value on hover when it was cut.
@MainActor
final class QuickViewTableCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("QuickViewTableCell")
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.allowsExpansionToolTips = true
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A line break inside a quoted value would push the rest of it below the row, so a cell draws
    /// one as a space; the strip shows the value as written.
    func show(_ value: String, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        let singleLine = value.contains(where: \.isNewline)
            ? value.split(whereSeparator: \.isNewline).joined(separator: " ")
            : value
        label.stringValue = singleLine
        label.font = font
        label.textColor = color
        label.alignment = alignment
    }
}

/// The table itself, which puts the selected rows on the pasteboard as tab-separated text — what a
/// spreadsheet reads back into cells.
@MainActor
final class QuickViewDataTableView: NSTableView, NSMenuItemValidation {
    var copiedText: ((IndexSet) -> String?)?
    /// Where ⌘C writes. The general pasteboard, except in a test, which must not overwrite the
    /// clipboard of whoever is running it.
    var pasteboard = NSPasteboard.general

    @objc func copy(_ sender: Any?) {
        guard let text = copiedText?(selectedRowIndexes), !text.isEmpty else {
            NSSound.beep()
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(text, forType: .tabularText)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return true }
        return !selectedRowIndexes.isEmpty
    }
}
