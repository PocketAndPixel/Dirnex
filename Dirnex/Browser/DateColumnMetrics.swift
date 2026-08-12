import AppKit

/// How wide the Date column opens — **measured**, not chosen.
///
/// Neither half of the answer is ours to pick. The date's shape comes from the user's *region*
/// (`.short`/`.short`, so `de_DE` draws `28.12.25, 22:58` where `ko_KR` draws
/// `2025. 12. 28. 오후 10:58` — 49 pt apart in the row font), and the header's from their *language*
/// (`Date Modified` at 95 pt against `Fecha de modificación` at 139). One hardcoded number cannot be
/// right for both, and the 150 pt this replaced was wrong in both directions at once: ~22 pt of
/// empty column in the `dd.MM.yyyy` regions, and short of the Korean date.
///
/// Two things it deliberately sizes *up* for. The row font is **bold** on a marked file, which is
/// wider — size to the unmarked form and marking a file truncates its date. And the sort indicator
/// is reserved whether or not the pane is sorted by date, so the header does not reflow the first
/// time someone clicks it.
///
/// Only the *default* is affected: a tab with a stored `ColumnLayout` keeps whatever the user
/// dragged, so this is the fresh-install width and nothing else.
@MainActor
enum DateColumnMetrics {
    /// Measured once. Both inputs are fixed for the life of the process — a language switch
    /// relaunches the app (`docs/NOTES.md`, Localization), and a region change is a system setting
    /// the running app does not track either.
    static let width: CGFloat = max(widestRowWidth, headerWidth).rounded(.up)

    /// The widest a row can draw here, taken from a real `FileCellView` — the class that actually
    /// draws this column, so the text field's own padding and the cell's leading/trailing insets
    /// come out of the live layout instead of from constants copied beside it.
    private static var widestRowWidth: CGFloat {
        let cell = FileCellView(showsImage: false, identifier: .init("dateColumnProbe"))
        // A mark is bold, and bold is the wide case.
        cell.marked = true
        return FileFormatting.dateStringShapes.reduce(0) { widest, text in
            cell.textField?.stringValue = text
            cell.applyStyle()
            return max(widest, cell.fittingSize.width)
        }
    }

    /// What the localized header needs, from `NSTableColumn`'s own arithmetic rather than a
    /// hand-rolled sum: `sizeToFit()` on a detached column fits its header cell and nothing else
    /// (there is no data source to consult), and with the indicator installed it accounts for the
    /// sort arrow's slot — measured at a constant 17 pt over the bare title, in every language.
    private static var headerWidth: CGFloat {
        let column = NSTableColumn(identifier: .init("dateColumnProbe"))
        column.title = PanelViewController.Column.date.title
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        let table = NSTableView()
        table.addTableColumn(column)
        table.setIndicatorImage(NSImage(named: "NSAscendingSortIndicator"), in: column)
        column.sizeToFit()
        return column.width
    }
}
