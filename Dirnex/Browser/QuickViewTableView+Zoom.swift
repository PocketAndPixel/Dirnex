import AppKit
import DirnexCore

/// ⌘+, ⌘−, ⌘0 and a pinch on Quick View's table (2026-09-15).
///
/// The zoom scales what the table is drawn with — the cell and header fonts, the row height, the
/// header's height, every column's width and the strip's fonts — rather than magnifying the scroll
/// view the way the text preview does. Measured before this was written: an `NSTableView` magnified 2×
/// draws its rows at twice the size under a column header that stays at 1×, so a column's title ends
/// up half a column away from its values. Scaling the drawing keeps the header aligned and the text
/// sharp at every level, for the price of a reload per step, which draws only the rows on screen.
///
/// The level is relative to how the table opened, on the ladder every preview shares
/// (`QuickViewZoom`), and a new file opens at 1.
extension QuickViewTableView {
    /// The row-number column's floor at level 1.
    static let minimumRowNumberWidth: CGFloat = 20

    /// A row's height at level 1: the cell font's line and 6 points of room.
    static let baseRowHeight = ceil(cellFont.ascender - cellFont.descender) + 6
    /// The header's font at level 1, which is AppKit's own for a table header (measured: the system
    /// font at the small size, regular weight).
    static let baseHeaderFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    /// Whether the table is as it opened, so ⌘0 has nothing to do.
    var isAtStartingZoom: Bool { abs(zoomLevel - 1) <= 0.005 }

    /// Zoom to `level`, within the ladder's two ends, keeping the row at the top of the view at the top
    /// and the view as far across the columns, in proportion, as it was.
    func setZoomLevel(_ level: Double) {
        let bounded = min(
            max(level, QuickViewZoom.levels.first ?? 1),
            QuickViewZoom.levels.last ?? 1
        )
        guard table != nil, abs(bounded - zoomLevel) > 0.0001 else { return }
        let topRow = firstVisibleRow
        let across = scrollView.contentView.bounds.minX / CGFloat(zoomLevel)
        zoomLevel = bounded
        applyZoom()
        applyZoomWidths()
        // Kept across the reload by hand: measured, `reloadData` after a zoom's changes leaves the table
        // with no selection and posts no notification, so the strip went on showing a row the table no
        // longer marked.
        let selected = tableView.selectedRowIndexes
        tableView.reloadData()
        selectProgrammatically(selected)
        restoreScroll(topRow: topRow, across: across * CGFloat(bounded))
        needsLayout = true
    }

    /// Every column at its base width times the level, and never narrower than its own header with a
    /// sort arrow in it, measured at this level.
    ///
    /// The floor is measured rather than scaled. A title that fits its width at one size does not
    /// reliably fit that width scaled to another, and the sort arrow does not scale at all, so widths
    /// that were only multiplied cut titles short on both sides of 1 (seen live on a load-test log:
    /// `responseCo…` at 0.8, `elap…` under its arrow at 1.75). The title is measured at this level's
    /// size, and the arrow's room is AppKit's own, measured once (`headerChrome`). The floor raises
    /// this level's width and leaves the base alone, so coming back to 1 gives the table as it opened.
    private func applyZoomWidths() {
        isApplyingZoomWidths = true
        defer { isApplyingZoomWidths = false }
        let scale = CGFloat(zoomLevel)
        for column in tableView.tableColumns {
            let base = baseWidths[column.identifier] ?? column.width / scale
            let header = headerWidth(of: column)
            column.minWidth = (column.identifier == Self.rowNumberColumn
                ? Self.minimumRowNumberWidth
                : Self.minimumColumnWidth) * scale
            column.width = max(base * scale, header)
        }
    }

    /// Back to level 1 for a new table, before its columns are built and measured at that size.
    func resetZoom() {
        zoomLevel = 1
        applyZoom()
    }

    /// Set a column's header title in the header font at the current level. An attributed title,
    /// because a header cell's `font` is ignored when the header draws (measured: set to 22 points,
    /// the title still drew at 11).
    func applyHeaderTitle(to column: NSTableColumn) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = column.headerCell.alignment
        paragraph.lineBreakMode = .byTruncatingTail
        column.headerCell.attributedStringValue = NSAttributedString(
            string: column.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: Self.baseHeaderFont.pointSize * CGFloat(zoomLevel)),
                .foregroundColor: NSColor.headerTextColor,
                .paragraphStyle: paragraph
            ]
        )
    }

    /// Everything a level changes except the column widths, which `applyZoomWidths` sets from their
    /// bases.
    private func applyZoom() {
        let scale = CGFloat(zoomLevel)
        zoomedCellFont = NSFont.monospacedDigitSystemFont(
            ofSize: Self.cellFont.pointSize * scale,
            weight: .regular
        )
        zoomedRowNumberFont = NSFont.monospacedDigitSystemFont(
            ofSize: Self.rowNumberFont.pointSize * scale,
            weight: .regular
        )
        tableView.rowHeight = max(ceil(Self.baseRowHeight * scale), 4)
        for column in tableView.tableColumns {
            applyHeaderTitle(to: column)
        }
        if let header = tableView.headerView, baseHeaderHeight > 0 {
            var frame = header.frame
            frame.size.height = max(round(baseHeaderHeight * scale), 12)
            header.frame = frame
        }
        tableView.tile()
        scrollView.tile()
        strip.scale = scale
    }

    /// The first row not hidden under the column header — the row a reader sees at the top. Not the
    /// row at the clip view's origin, which the header and the title bar cover (`QuickViewTableScrolling`).
    var firstVisibleRow: Int {
        QuickViewTableScrolling.firstVisibleRow(of: tableView, in: scrollView)
    }

    /// Put `topRow` back just under the header and the view `across` points into the columns.
    private func restoreScroll(topRow: Int, across: CGFloat) {
        QuickViewTableScrolling.restore(
            topRow: topRow,
            across: across,
            of: tableView,
            in: scrollView
        )
    }
}
