import AppKit

/// Where somebody reading a table is, kept across a change to how tall its rows are — the zoom of the
/// CSV table and of the JSON tree (split out of `QuickViewTableView+Zoom` when the tree gained a zoom,
/// 2026-09-15).
///
/// By row rather than by offset. The column header floats over the rows, and in the browser window the
/// title bar does too, so the clip view's origin sits above what anyone can see (measured: 60 points,
/// two or three rows) — and the header's own height changes with the level.
@MainActor
enum QuickViewTableScrolling {
    /// The first row not hidden under the column header: the row a reader sees at the top.
    static func firstVisibleRow(of tableView: NSTableView, in scrollView: NSScrollView) -> Int {
        let top = visibleRowsTop(of: tableView, in: scrollView)
        return max(tableView.row(at: NSPoint(x: 0, y: top + 1)), 0)
    }

    /// Put `topRow` back just under the header, and the view `across` points into the columns.
    static func restore(
        topRow: Int,
        across: CGFloat,
        of tableView: NSTableView,
        in scrollView: NSScrollView
    ) {
        let clip = scrollView.contentView
        let covered = visibleRowsTop(of: tableView, in: scrollView) - clip.bounds.minY
        let rowTop = topRow < tableView.numberOfRows ? tableView.rect(ofRow: topRow).minY : 0
        clip.scroll(to: NSPoint(x: max(across, 0), y: rowTop - covered))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Where, in the table's own coordinates, the rows stop being covered: the header's lower edge, or
    /// the clip view's top when the header does not overlap the rows at all.
    private static func visibleRowsTop(of tableView: NSTableView, in scrollView: NSScrollView) -> CGFloat {
        let clip = scrollView.contentView
        guard let header = tableView.headerView, header.window != nil else { return clip.bounds.minY }
        let headerBottom = clip.convert(header.bounds, from: header).maxY
        return max(clip.bounds.minY, headerBottom)
    }
}
