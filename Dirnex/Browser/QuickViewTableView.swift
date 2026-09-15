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
    /// The strip's top edge, which a drag moves (`QuickViewTableView+StripHeight`).
    let stripHandle = QuickViewStripHandle()
    private let truncationNotice = QuickViewTruncationNotice()
    /// Internal, not private, for `QuickViewTableView+StripHeight`, which sets it.
    var stripHeight: NSLayoutConstraint?
    /// Where the height somebody dragged the strip to is kept: the app's own defaults, or a
    /// test's scratch domain (docs/NOTES.md ▸ Testing).
    let layoutDefaults: UserDefaults

    /// The table on screen, or `nil` once cleared.
    private(set) var table: DelimitedTable?

    /// The rows drawn and in what order: the sort's order, narrowed to the filter's matches. Rebuilt by
    /// `reloadRows` whenever either changes.
    var rows = DelimitedTableRows(rowCount: 0)

    // The sort's state, kept here because an extension cannot hold any
    // (`QuickViewTableView+Sorting` owns every rule about it).

    /// The data rows in the order the sort put them, or `nil` while they are in the file's order.
    var sortOrder: [Int]?
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

    // The filter's state, for the same reason (`QuickViewTableView+Filter`).

    /// The bar over the table, hidden until ⌥⌘F.
    let filterBar = QuickViewTableFilterBar()
    /// For each data row, whether the filter keeps it, or `nil` while no text is typed.
    var filterMatches: [Bool]?
    /// Bumped by every change to the filter and every new table, so a filter landing after either is
    /// discarded.
    var filterGeneration = 0
    /// The last filter sent off the main actor — what a test awaits, as it does a sort's.
    var filterTask: Task<Void, Never>?
    /// What stops that filter early once a newer one makes it pointless.
    var filterCancellation: CancellationFlag?
    /// The query the rows on screen were filtered by, and the column the picker named, which the cells
    /// mark.
    var filterMarking: (query: FilterQuery, column: Int?)?
    /// The scroll view's top edge: against the surface, or under the filter bar while it is shown.
    var filterTopToSurface: NSLayoutConstraint?
    var filterTopToBar: NSLayoutConstraint?
    /// Where the keyboard goes when the filter bar lets go of it: the file list the arrows walk. Set
    /// by whoever opens the bar, since the surface does not know which list that is.
    var returnKeyboard: (() -> Void)?

    // The zoom's state, for the same reason (`QuickViewTableView+Zoom`).

    /// ⌘+'s level, relative to the table as it opened.
    var zoomLevel: Double = 1
    /// The fonts cells draw in at `zoomLevel`.
    var zoomedCellFont = QuickViewTableView.cellFont
    var zoomedRowNumberFont = QuickViewTableView.rowNumberFont
    /// The column header's height as AppKit built it, which a zoom scales.
    var baseHeaderHeight: CGFloat = 0
    /// Each column's width at level 1 — as measured, or as somebody dragged it, divided back out of
    /// the level it was dragged at. What a zoom scales, so a step never builds on a width the header
    /// floor raised at another level.
    var baseWidths: [NSUserInterfaceItemIdentifier: CGFloat] = [:]
    /// Set while a zoom sets widths itself, which is not somebody resizing a column.
    var isApplyingZoomWidths = false

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

    init(layoutDefaults: UserDefaults) {
        self.layoutDefaults = layoutDefaults
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildTable()
        buildStrip()
        buildNotice()
        installStripHandle()
        installFilterBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// Show `table`, back at its top-left with its first row selected, unsorted and unfiltered.
    func show(_ table: DelimitedTable, isTruncated: Bool) {
        resetSort()
        resetFilter()
        resetZoom()
        self.table = table
        rows = DelimitedTableRows(rowCount: table.rowCount)
        rebuildColumns(for: table)
        filterBar.setColumns((0..<table.columnCount).map(table.title(ofColumn:)))
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
        resetFilter()
        table = nil
        rows = DelimitedTableRows(rowCount: 0)
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
        guard let table, tableView.selectedRow >= 0, tableView.selectedRow < rows.count else {
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

    // MARK: - Layout

    /// A pinch zooms the table the way ⌘+ and ⌘− do, continuously rather than by steps.
    override func magnify(with event: NSEvent) {
        guard table != nil else {
            super.magnify(with: event)
            return
        }
        setZoomLevel(zoomLevel * (1 + Double(event.magnification)))
    }

    /// The strip fits its row, or keeps the height it was dragged to, and scrolls past either
    /// (`QuickViewTableView+StripHeight`).
    override func layout() {
        updateStripHeight()
        super.layout()
    }

    private func buildTable() {
        tableView.style = .plain
        tableView.font = Self.cellFont
        tableView.rowHeight = Self.baseRowHeight
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
        baseHeaderHeight = tableView.headerView?.frame.height ?? 0
    }

    private func buildStrip() {
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        let height = strip.heightAnchor.constraint(equalToConstant: 0)
        stripHeight = height
        let top = scrollView.topAnchor.constraint(equalTo: topAnchor)
        filterTopToSurface = top
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            top,
            scrollView.bottomAnchor.constraint(equalTo: strip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            height
        ])
    }

    /// The same "first 4 MB" notice the text view floats, over the bottom of the table.
    private func buildNotice() {
        truncationNotice.install(in: self, above: scrollView.bottomAnchor)
    }
}

// MARK: - Rows and cells

extension QuickViewTableView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        table == nil ? 0 : rows.count
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
                font: zoomedRowNumberFont,
                color: .secondaryLabelColor,
                alignment: .right
            )
            return cell
        }
        guard let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let isNumeric = table.numericColumns.indices.contains(column) && table.numericColumns[column]
        cell.show(
            table.cell(row: record, column: column),
            font: zoomedCellFont,
            color: .labelColor,
            alignment: isNumeric ? .right : .left,
            marking: filterMarking.flatMap { $0.column == nil || $0.column == column ? $0.query : nil }
        )
        return cell
    }

    /// A column somebody dragged keeps its new width, in proportion, through later zooms.
    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isApplyingZoomWidths,
              let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn
        else { return }
        baseWidths[column.identifier] = column.width / CGFloat(zoomLevel)
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
