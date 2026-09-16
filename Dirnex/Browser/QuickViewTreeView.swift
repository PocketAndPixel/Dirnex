import AppKit
import DirnexCore

/// A JSON, XML or property-list file as a tree of its keys or names and their values, with the selected
/// value's path and its whole text in the strip underneath — one of `QuickViewPreviewView`'s backends
/// (`QuickViewPreviewView+Tree`). Built for JSON (2026-09-15), and made to read any `TreeDocument` when
/// XML became the second format drawn as a tree (2026-09-16), so the two share one outline view, one
/// strip, one filter and one zoom rather than growing apart.
///
/// Built like the CSV table beside it and from its parts: the strip and its drag handle, the cells,
/// the "first 4 MB" notice and the zoom's ladder. Two columns, the key or name and the value, with the
/// text of each coming from the document (`TreeDocument.keyLabel`, `valueLabel`) and its color from the
/// source view's for its kind (`SyntaxTheme`).
///
/// The first row is selected as a file opens, so the strip says something before anything is clicked.
/// The arrows belong to the file list, as they do over the table, so a container opens by its
/// disclosure triangle or a double-click on its row; ⌥-click on a triangle opens everything under it,
/// which is the outline view's own.
@MainActor
final class QuickViewTreeView: NSView {
    let scrollView = NSScrollView()
    let outlineView = QuickViewTreeOutlineView()
    let strip = QuickViewRecordStrip()
    /// The strip's top edge, which a drag moves (`QuickViewTreeView+Layout`).
    let stripHandle = QuickViewStripHandle()
    let truncationNotice = QuickViewTruncationNotice()
    /// Internal, not private, for `QuickViewTreeView+Layout`, which sets it.
    var stripHeight: NSLayoutConstraint?
    /// Where the height somebody dragged the strip to is kept: the app's own defaults, or a test's
    /// scratch domain (docs/NOTES.md ▸ Testing).
    let layoutDefaults: UserDefaults

    /// The document on screen, or `nil` once cleared.
    private(set) var document: (any TreeDocument)?
    /// The values listed at the top of the tree, kept because the outline view asks for them one at a
    /// time — the filter's, while there is one.
    var topLevel: [Int] = []
    /// One object per value the outline view has been handed. It keeps a row's expanded state against
    /// the object, so a value has to come back as the same object every time it is asked for.
    private var items: [Int: QuickViewTreeItem] = [:]
    /// What the first column names, which titles it and the filter's picker.
    private var labelNoun = TreeLabelNoun.key

    // The zoom's state, kept here because an extension cannot hold any (`QuickViewTreeView+Layout`).

    /// ⌘+'s level, relative to the tree as it opened.
    var zoomLevel: Double = 1
    /// The font cells draw in at `zoomLevel`.
    var zoomedFont = QuickViewTableView.cellFont
    /// The column header's height as AppKit built it, which a zoom scales.
    var baseHeaderHeight: CGFloat = 0
    /// The key column's width at level 1: as measured, or as somebody dragged it.
    var baseKeyWidth: CGFloat = 0
    /// Set while a zoom sets the key column's width itself, which is not somebody resizing it.
    var isApplyingZoom = false

    // The filter's state, for the same reason (`QuickViewTreeView+Filter`).

    /// The bar over the tree, hidden until ⌥⌘F.
    let filterBar = QuickViewTableFilterBar()
    /// What the filter found, or `nil` while no text is typed.
    var filter: TreeFilter?
    /// Bumped by every change to the filter and every new document, so a filter landing after either
    /// is discarded.
    var filterGeneration = 0
    var filterTask: Task<Void, Never>?
    /// What stops that filter early once a newer one makes it pointless.
    var filterCancellation: CancellationFlag?
    var filterTopToSurface: NSLayoutConstraint?
    var filterTopToBar: NSLayoutConstraint?
    var returnKeyboard: (() -> Void)?
    /// The containers open before the filter, in row order, opened again when it is cleared.
    var expandedBeforeFilter: [Int]?
    /// Each container's children under the filter, as far as the outline view has asked.
    var filteredChildren: [Int: [Int]] = [:]
    /// The query and the picker's choice the tree on screen was filtered by, which its cells mark.
    var filterMarking: (query: FilterQuery, scope: TreeFilterScope)?

    static let keyColumn = NSUserInterfaceItemIdentifier("key")
    static let valueColumn = NSUserInterfaceItemIdentifier("value")
    /// How many rows a file may open showing before its bigger containers are left closed
    /// (`TreeDocument.initialExpansion`): a `package.json` opens whole, an array of ten thousand closed.
    static let initialRowBudget = 200
    /// The most of a value the strip shows. The strip measures its text on every layout, so a 4 MB value
    /// would cost that on every layout; ⌘C still copies the whole value.
    static let stripTextLimit = 64 * 1024
    static let baseIndentation: CGFloat = 16
    static let minimumKeyWidth: CGFloat = 90
    static let maximumKeyWidth: CGFloat = 360
    /// What a key's cell needs beside its text: the disclosure triangle and the cell's own padding.
    static let keyChrome: CGFloat = 34

    init(layoutDefaults: UserDefaults) {
        self.layoutDefaults = layoutDefaults
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildOutline()
        buildStrip()
        truncationNotice.install(in: self, above: scrollView.bottomAnchor)
        installStripHandle()
        installFilterBar()
        filterBar.setScopes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// Show `document`, at its top with its first row selected and its small containers open.
    func show(_ document: any TreeDocument) {
        resetFilter()
        if document.labelNoun != labelNoun {
            labelNoun = document.labelNoun
            outlineView.tableColumn(withIdentifier: Self.keyColumn)?.title = Self.keyTitle(
                for: labelNoun
            )
            filterBar.setScopes(naming: labelNoun)
        }
        zoomLevel = 1
        applyZoom()
        self.document = document
        topLevel = document.topLevelValues
        items = [:]
        outlineView.reloadData()
        for value in document.initialExpansion(rowBudget: Self.initialRowBudget) {
            outlineView.expandItem(item(for: value))
        }
        sizeKeyColumn()
        // To the first row, not to the document's origin, for the reason the table gives: the header
        // floats over the rows (`QuickViewTableView.show`).
        if outlineView.numberOfRows > 0 {
            outlineView.scrollRowToVisible(0)
            outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        outlineView.scrollColumnToVisible(0)
        showSelectedValue()
        truncationNotice.isHidden = !document.isTruncated
        needsLayout = true
    }

    func clearDocument() {
        resetFilter()
        document = nil
        topLevel = []
        items = [:]
        outlineView.reloadData()
        strip.clear()
        truncationNotice.isHidden = true
    }

    /// The object standing for `value`, made the first time it is asked for.
    func item(for value: Int) -> QuickViewTreeItem {
        if let item = items[value] { return item }
        let item = QuickViewTreeItem(value: value)
        items[value] = item
        return item
    }

    /// The value on the selected row, if any.
    var selectedValue: Int? {
        (outlineView.item(atRow: outlineView.selectedRow) as? QuickViewTreeItem)?.value
    }

    /// The selected value's path and text in the strip.
    func showSelectedValue() {
        guard let document, let value = selectedValue else {
            strip.clear()
            needsLayout = true
            return
        }
        strip.show([
            (Self.pathTitle, document.path(of: value)),
            (Self.valueTitle, document.stripText(of: value, byteLimit: Self.stripTextLimit))
        ])
        needsLayout = true
    }

    /// What ⌘C puts on the pasteboard: the selected value whole — a JSON string's text or a container as
    /// indented JSON, an XML value's text or an element as its source.
    func copiedValueText() -> String? {
        guard let document, let value = selectedValue else { return nil }
        return document.copiedText(of: value)
    }

    /// A double-click opens a closed container on its row, and closes an open one.
    @objc func toggleClickedRow(_ sender: Any?) {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) else { return }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else if outlineView.isExpandable(item) {
            outlineView.expandItem(item)
        }
    }

    /// Whether the tree is wider than the surface, so a sideways two-finger scroll pans it rather than
    /// turning to the next file — the table's rule.
    var pansHorizontally: Bool {
        guard let document = scrollView.documentView else { return false }
        return document.frame.width > scrollView.contentView.bounds.width + 0.5
    }

    // MARK: - Layout

    /// A pinch zooms the tree the way ⌘+ and ⌘− do, continuously rather than by steps.
    override func magnify(with event: NSEvent) {
        guard document != nil else {
            super.magnify(with: event)
            return
        }
        setZoomLevel(zoomLevel * (1 + Double(event.magnification)))
    }

    override func layout() {
        updateStripHeight()
        super.layout()
    }

    /// The key column as wide as the widest key among the rows the tree opened with, at its depth,
    /// within the two bounds. The value column takes the rest, and follows the surface as it resizes.
    func sizeKeyColumn() {
        guard let column = outlineView.tableColumn(withIdentifier: Self.keyColumn) else { return }
        let font = QuickViewTableView.cellFont
        var widest = ceil((Self.keyTitle(for: labelNoun) as NSString)
            .size(withAttributes: [.font: QuickViewTableView.baseHeaderFont]).width) + 20
        for row in 0..<min(outlineView.numberOfRows, 500) {
            guard let item = outlineView.item(atRow: row) as? QuickViewTreeItem else { continue }
            let text = String((document?.keyLabel(of: item.value).text ?? "").prefix(60))
            let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            let indent = CGFloat(outlineView.level(forRow: row)) * Self.baseIndentation
            widest = max(widest, width + indent + Self.keyChrome)
        }
        baseKeyWidth = min(max(widest, Self.minimumKeyWidth), Self.maximumKeyWidth)
        isApplyingZoom = true
        column.width = baseKeyWidth * CGFloat(zoomLevel)
        isApplyingZoom = false
    }

    private func buildOutline() {
        outlineView.style = .plain
        outlineView.rowHeight = QuickViewTableView.baseRowHeight
        outlineView.intercellSpacing = NSSize(width: 6, height: 0)
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnSelection = false
        outlineView.indentationPerLevel = Self.baseIndentation
        outlineView.autoresizesOutlineColumn = false

        let key = NSTableColumn(identifier: Self.keyColumn)
        key.title = Self.keyTitle(for: labelNoun)
        key.resizingMask = .userResizingMask
        key.minWidth = 40
        key.maxWidth = 10000
        let value = NSTableColumn(identifier: Self.valueColumn)
        value.title = Self.valueTitle
        value.resizingMask = [.autoresizingMask, .userResizingMask]
        value.minWidth = 80
        value.maxWidth = 100_000
        outlineView.addTableColumn(key)
        outlineView.addTableColumn(value)
        outlineView.outlineTableColumn = key

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(toggleClickedRow(_:))
        outlineView.copiedText = { [weak self] in self?.copiedValueText() }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView
        addSubview(scrollView)
        baseHeaderHeight = outlineView.headerView?.frame.height ?? 0
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

    // MARK: - Words

    static var keyTitle: String {
        String(
            localized: "Key",
            comment: "Quick View JSON tree column header: the key a value is stored under"
        )
    }

    /// The first column's header: a key for JSON and a property list, a name for XML.
    static func keyTitle(for noun: TreeLabelNoun) -> String {
        switch noun {
        case .key: keyTitle
        case .name: nameTitle
        }
    }

    static var nameTitle: String {
        String(
            localized: "Name",
            comment: "Quick View XML tree column header: an element's or attribute's name."
        )
    }

    static var valueTitle: String {
        String(
            localized: "Value",
            comment: "Quick View tree column header, and the strip's name for the selected value's text"
        )
    }

    static var pathTitle: String {
        String(
            localized: "Path",
            comment: """
            Quick View tree strip: the name beside the selected value's path, such as $.name, \
            /Project/ItemGroup or :CFBundleName
            """
        )
    }
}
