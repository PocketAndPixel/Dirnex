import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The Date column's default width (`DateColumnMetrics`). It replaced a hardcoded 150 pt, which was
/// wrong in both directions at once — ~22 pt of empty column in the `dd.MM.yyyy, HH:mm` regions, and
/// narrower than a Korean date — so what is worth pinning is *both* edges: the width holds everything
/// this machine's region and language can draw, and it is not padded past that.
///
/// Deliberately locale-agnostic. The suite runs inside the app, which inherits whatever
/// `AppleLanguages` the developer pinned Dirnex to (`docs/NOTES.md`, Localization), and the *region*
/// is the running Mac's — so every assertion here re-derives its expectation instead of naming a
/// number that only holds in one place.
@Suite("Date column width")
@MainActor
struct DateColumnMetricsTests {
    /// A cell configured the way the pane's marked rows are — the wide case, since a mark is bold.
    private func markedDateCell(showing text: String) -> FileCellView {
        let cell = FileCellView(showsImage: false, identifier: .init("test.date"))
        cell.marked = true
        cell.textField?.stringValue = text
        cell.applyStyle()
        return cell
    }

    @Test("the sampled shapes come from the same formatter the rows do")
    func shapesMatchTheRenderedDate() throws {
        // The measurement is only worth anything if it measures what a row actually draws. Sampling
        // through a second `DateFormatter` would compile, look right, and drift the day either one
        // changed — so pin that a real entry's rendered date is one of the sampled shapes.
        var components = DateComponents()
        components.year = 2025
        components.month = 12
        components.day = 28
        components.hour = 22
        components.minute = 58
        let date = try #require(Calendar(identifier: .gregorian).date(from: components))
        let entry = FileEntry(
            path: VFSPath(backend: .local, path: "/tmp/x"),
            name: "x",
            kind: .file,
            byteSize: 0,
            modificationDate: date,
            creationDate: date,
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
        let shapes = FileFormatting.dateStringShapes
        #expect(shapes.count == 24)
        #expect(shapes.contains(FileFormatting.dateString(for: entry)))
    }

    @Test(
        "a marked row's date fits at the default width, in every month and both halves of the clock"
    )
    func fitsEveryDateShape() {
        // Bold is the wide form, so this is the assertion that catches a width measured against the
        // unmarked font: marking a file would truncate its date where an unmarked one fits.
        for text in FileFormatting.dateStringShapes {
            let needed = markedDateCell(showing: text).fittingSize.width
            #expect(
                needed <= PanelViewController.Column.date.defaultWidth,
                "“\(text)” needs \(needed) pt"
            )
        }
    }

    @Test("the localized header fits, with room for the sort indicator")
    func fitsTheHeader() {
        // Reserved whether or not the pane is sorted by date — otherwise the title reflows (and can
        // start truncating) the first time someone clicks the header.
        let column = NSTableColumn(identifier: .init("test.date"))
        column.title = PanelViewController.Column.date.title
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        let table = NSTableView()
        table.addTableColumn(column)
        table.setIndicatorImage(NSImage(named: "NSAscendingSortIndicator"), in: column)
        column.sizeToFit()
        #expect(column.width <= PanelViewController.Column.date.defaultWidth)
    }

    @Test("and is no wider than what it has to hold")
    func isNotPadded() {
        // The half that keeps this a measurement rather than a generous guess: the whole reported
        // problem was slack, so a future edit that pads "just to be safe" — or re-hardcodes a number
        // that happens to clear both requirements here — fails.
        let widestRow = FileFormatting.dateStringShapes
            .map { markedDateCell(showing: $0).fittingSize.width }
            .max() ?? 0
        let column = NSTableColumn(identifier: .init("test.date"))
        column.title = PanelViewController.Column.date.title
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        let table = NSTableView()
        table.addTableColumn(column)
        table.setIndicatorImage(NSImage(named: "NSAscendingSortIndicator"), in: column)
        column.sizeToFit()
        // One point of headroom: the width is rounded up off a fractional measurement.
        #expect(PanelViewController.Column.date.defaultWidth <= max(widestRow, column.width) + 1)
    }
}
