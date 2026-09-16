import AppKit
import DirnexCore

/// How tall the strip under the JSON tree is, and ⌘+, ⌘−, ⌘0 and a pinch on the tree (2026-09-15).
///
/// Both follow the CSV table's rules (`QuickViewTableView+StripHeight`, `QuickViewTableView+Zoom`) and
/// share its arithmetic, so the two surfaces cannot drift apart. The strip fits the selected value up
/// to two fifths of the surface until somebody drags its edge; the zoom scales what the tree is drawn
/// with — fonts, row height, indentation, the header and the key column — rather than magnifying the
/// scroll view, which leaves an outline view's header at 1× over rows at 2×, as it does a table's.
extension QuickViewTreeView {
    // MARK: - The strip

    /// Where a dragged height is kept — apart from the table's, since a tree's strip shows a path and
    /// one value where a table's shows a field for every column.
    static let stripHeightKey = "Dirnex.quickView.jsonStripHeight"

    /// The height somebody dragged the strip to, or `nil` while it fits its value.
    var chosenStripHeight: CGFloat? {
        get {
            (layoutDefaults.object(forKey: Self.stripHeightKey) as? NSNumber)
                .map { CGFloat($0.doubleValue) }
        }
        set {
            if let newValue {
                layoutDefaults.set(Double(newValue), forKey: Self.stripHeightKey)
            } else {
                layoutDefaults.removeObject(forKey: Self.stripHeightKey)
            }
        }
    }

    func updateStripHeight() {
        let height = strip.isEmpty ? 0 : QuickViewTableView.stripHeight(
            chosen: chosenStripHeight,
            fitting: strip.fittingHeight(forWidth: bounds.width),
            surface: roomBelowFilterBar
        )
        if let stripHeight, abs(stripHeight.constant - height) > 0.5 {
            stripHeight.constant = height
        }
        stripHandle.isHidden = height == 0
    }

    /// The handle along the strip's top edge, placed as the table's is.
    func installStripHandle() {
        stripHandle.translatesAutoresizingMaskIntoConstraints = false
        stripHandle.isHidden = true
        addSubview(stripHandle)
        NSLayoutConstraint.activate([
            stripHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripHandle.topAnchor.constraint(equalTo: strip.topAnchor),
            stripHandle.heightAnchor.constraint(
                equalToConstant: QuickViewTableView.stripHandleHeight
            )
        ])
        stripHandle.currentHeight = { [weak self] in self?.strip.frame.height ?? 0 }
        stripHandle.resize = { [weak self] height in
            guard let self else { return }
            chosenStripHeight = round(QuickViewTableView.clampedStripHeight(
                height,
                surface: roomBelowFilterBar
            ))
            needsLayout = true
        }
        stripHandle.fit = { [weak self] in
            self?.chosenStripHeight = nil
            self?.needsLayout = true
        }
    }

    // MARK: - The zoom

    /// Whether the tree is as it opened, so ⌘0 has nothing to do.
    var isAtStartingZoom: Bool {
        abs(zoomLevel - 1) <= 0.005
    }

    /// Zoom to `level`, within the ladder's two ends, keeping the row at the top of the view at the top.
    func setZoomLevel(_ level: Double) {
        let bounded = min(
            max(level, QuickViewZoom.levels.first ?? 1),
            QuickViewZoom.levels.last ?? 1
        )
        guard document != nil, abs(bounded - zoomLevel) > 0.0001 else { return }
        let topRow = QuickViewTableScrolling.firstVisibleRow(of: outlineView, in: scrollView)
        let across = scrollView.contentView.bounds.minX / CGFloat(zoomLevel)
        zoomLevel = bounded
        applyZoom()
        QuickViewTableScrolling.restore(
            topRow: topRow,
            across: across * CGFloat(bounded),
            of: outlineView,
            in: scrollView
        )
        needsLayout = true
    }

    /// Everything a level changes, and the rows drawn again in it. Rows are reloaded in place rather
    /// than with `reloadData`, so what is open stays open and the selection stays where it is.
    func applyZoom() {
        isApplyingZoom = true
        defer { isApplyingZoom = false }
        let scale = CGFloat(zoomLevel)
        zoomedFont = NSFont.monospacedDigitSystemFont(
            ofSize: QuickViewTableView.cellFont.pointSize * scale,
            weight: .regular
        )
        outlineView.rowHeight = max(ceil(QuickViewTableView.baseRowHeight * scale), 4)
        outlineView.indentationPerLevel = Self.baseIndentation * scale
        // An attributed title, because a header cell's `font` is ignored when the header draws
        // (docs/NOTES.md ▸ AppKit).
        let headerFont = NSFont.systemFont(
            ofSize: QuickViewTableView.baseHeaderFont.pointSize * scale
        )
        for column in outlineView.tableColumns {
            column.headerCell.attributedStringValue = NSAttributedString(
                string: column.title,
                attributes: [.font: headerFont, .foregroundColor: NSColor.headerTextColor]
            )
        }
        if let header = outlineView.headerView, baseHeaderHeight > 0 {
            var frame = header.frame
            frame.size.height = max(round(baseHeaderHeight * scale), 12)
            header.frame = frame
        }
        if baseKeyWidth > 0 {
            outlineView.tableColumn(withIdentifier: Self.keyColumn)?.width = baseKeyWidth * scale
        }
        outlineView.tile()
        scrollView.tile()
        strip.scale = scale
        let rows = outlineView.numberOfRows
        if rows > 0 {
            outlineView.reloadData(
                forRowIndexes: IndexSet(integersIn: 0..<rows),
                columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns)
            )
        }
    }
}
