import AppKit
import DirnexCore

/// Building the byte view (PLAN.md §M37 Slice 2): the text window's toolbar with only its change
/// arrows and counter showing, the banner, the table and the overview strip.
extension BinaryCompareWindowController {
    /// Lay the views out in `window` and wire each control to the controller. Called once, from
    /// `init`.
    func buildContent(in window: NSWindow) {
        toolbar.showOnlyNavigation()
        toolbar.onPrevious = { [weak self] in self?.goToPreviousChange() }
        toolbar.onNext = { [weak self] in self?.goToNextChange() }
        overview.onJump = { [weak self] row in self?.jump(toRow: row) }
        banner.textColor = .secondaryLabelColor
        banner.translatesAutoresizingMaskIntoConstraints = false
        buildTable()

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [scrollView, overview] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        let column = NSStackView(views: [toolbar, banner, body])
        column.orientation = .vertical
        column.spacing = 0
        column.setHuggingPriority(.defaultLow, for: .vertical)
        column.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toolbar.widthAnchor.constraint(equalTo: column.widthAnchor),
            body.widthAnchor.constraint(equalTo: column.widthAnchor),
            banner.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -12),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            overview.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            overview.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            overview.widthAnchor.constraint(equalToConstant: CompareOverviewView.width)
        ])
        for view in [scrollView, overview] as [NSView] {
            view.topAnchor.constraint(equalTo: body.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor).isActive = true
        }
        window.contentView = content
        window.title = "\(left.name) ↔ \(right.name)"

        // Tab goes from the table to the toolbar's arrows and back.
        table.nextKeyView = toolbar.navigation
        toolbar.navigation.nextKeyView = table
        window.initialFirstResponder = table
        refreshCounter()
        overview.rowCount = rowCount
    }

    private func buildTable() {
        table.style = .plain
        table.rowHeight = BinaryCompareStyle.rowHeight
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsTypeSelect = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.backgroundColor = .textBackgroundColor
        table.gridStyleMask = .solidVerticalGridLineMask
        table.gridColor = .separatorColor

        addColumn(
            offsetColumn,
            title: String(
                localized: "Offset",
                comment: "Byte comparison window: the column of byte offsets."
            ),
            toolTip: nil,
            width: BinaryCompareStyle.offsetWidth(digits: offsetDigits)
        )
        addColumn(
            leftColumn,
            title: left.detail,
            toolTip: left.detail,
            width: BinaryCompareStyle.sideWidth
        )
        addColumn(
            rightColumn,
            title: right.detail,
            toolTip: right.detail,
            width: BinaryCompareStyle.sideWidth
        )
        table.dataSource = self
        table.delegate = self

        scrollView.documentView = table
        table.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func addColumn(_ column: NSTableColumn, title: String, toolTip: String?, width: CGFloat) {
        column.title = title
        column.headerToolTip = toolTip
        column.headerCell.lineBreakMode = .byTruncatingMiddle
        column.width = width
        column.minWidth = width
        column.maxWidth = width
        table.addTableColumn(column)
    }
}
