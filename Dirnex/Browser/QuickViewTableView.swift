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
        self.table = table
        rebuildColumns(for: table)
        tableView.reloadData()
        // To the first row and column, not to the document's origin. The column header floats over
        // the rows, so the scroll view rests *above* the origin by the header's height (plus the title
        // bar's, in a full-size window), and `scroll(.zero)` put row 1 under the header — found live.
        if table.rowCount > 0 {
            tableView.scrollRowToVisible(0)
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        if table.columnCount > 0 {
            tableView.scrollColumnToVisible(0)
        }
        showSelectedRecord()
        truncationNotice.isHidden = !isTruncated
        needsLayout = true
    }

    func clearTable() {
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
        let row = tableView.selectedRow
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
        rowNumbers.width = ceil(
            ("\(max(table.rowCount, 1))" as NSString)
                .size(withAttributes: [.font: Self.rowNumberFont]).width
        ) + 16
        rowNumbers.resizingMask = []
        tableView.addTableColumn(rowNumbers)

        let sampledRows = min(
            table.rowCount,
            max(8, Self.measurementBudget / max(table.columnCount, 1))
        )
        for index in 0..<table.columnCount {
            let title = table.title(ofColumn: index)
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = title
            column.headerToolTip = title
            if table.numericColumns.indices.contains(index), table.numericColumns[index] {
                column.headerCell.alignment = .right
            }
            column.width = Self.width(
                ofColumn: index,
                titled: title,
                in: table,
                sampling: sampledRows
            )
            column.minWidth = Self.minimumColumnWidth
            column.maxWidth = 10000
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
        }
    }

    /// Wide enough for the title and the widest sampled value, within the two bounds. A value is
    /// measured by its first 80 characters, which is already past the widest column allowed.
    private static func width(
        ofColumn column: Int,
        titled title: String,
        in table: DelimitedTable,
        sampling rows: Int
    ) -> CGFloat {
        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        var widest = (title as NSString).size(withAttributes: [.font: headerFont]).width
        for row in 0..<rows {
            let value = String(table.cell(row: row, column: column).prefix(80))
            guard !value.isEmpty else { continue }
            widest = max(widest, (value as NSString).size(withAttributes: [.font: cellFont]).width)
        }
        return min(max(ceil(widest) + 14, minimumColumnWidth), maximumColumnWidth)
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
            self?.table?.tabSeparatedText(rows: Array(rows))
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
        if tableColumn.identifier == Self.rowNumberColumn {
            cell.show(
                "\(row + 1)",
                font: Self.rowNumberFont,
                color: .secondaryLabelColor,
                alignment: .right
            )
            return cell
        }
        guard let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let isNumeric = table.numericColumns.indices.contains(column) && table.numericColumns[column]
        cell.show(
            table.cell(row: row, column: column),
            font: Self.cellFont,
            color: .labelColor,
            alignment: isNumeric ? .right : .left
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showSelectedRecord()
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
