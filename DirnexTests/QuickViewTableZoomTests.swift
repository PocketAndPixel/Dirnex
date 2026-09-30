import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Zooming Quick View's table (2026-09-15): what a step scales, that the column header stays over its
/// column — the thing magnifying the scroll view got wrong, measured before this was built — and that
/// ⌘0 and a new file both go back to the table as it opened.
@Suite("Quick View table zoom")
@MainActor
struct QuickViewTableZoomTests {
    private static let sample = (1...120).map { "item\($0),\($0 * 7),note \($0)" }
        .joined(separator: "\n")

    @Test("a step scales the fonts, the row height, the header and the columns")
    func stepScalesTheDrawing() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let (preview, surface) = (fixture.preview, fixture.surface)
        let rowHeight = surface.tableView.rowHeight
        let headerHeight = try #require(surface.tableView.headerView?.frame.height)
        let width = surface.tableView.tableColumns[1].width

        surface.setZoomLevel(2)
        #expect(surface.zoomedCellFont.pointSize == QuickViewTableView.cellFont.pointSize * 2)
        #expect(abs(surface.tableView.rowHeight - rowHeight * 2) <= 1)
        #expect(abs((surface.tableView.headerView?.frame.height ?? 0) - headerHeight * 2) <= 1)
        #expect(abs(surface.tableView.tableColumns[1].width - width * 2) <= 1)
        let title = surface.tableView.tableColumns[1].headerCell.attributedStringValue
        let font = title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == QuickViewTableView.baseHeaderFont.pointSize * 2)
        #expect(title.string == "name")
        #expect(preview.canResetZoom)
        // The row selected as the table opened is still selected, and still an automatic choice.
        #expect(surface.tableView.selectedRow == 0)
        #expect(surface.selectionIsAutomatic)
    }

    /// The reason the zoom scales the drawing instead of magnifying: a magnified table draws its rows
    /// at the new size under a header left at the old one.
    @Test("every column's header stays over the column at every level")
    func headerStaysOverItsColumn() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let surface = fixture.surface
        for level in [0.5, 1.5, 3.0] {
            surface.setZoomLevel(level)
            surface.superview?.layoutSubtreeIfNeeded()
            let header = try #require(surface.tableView.headerView)
            for column in 0..<surface.tableView.numberOfColumns {
                let title = header.convert(header.headerRect(ofColumn: column), to: nil)
                let cells = surface.tableView.convert(
                    surface.tableView.rect(ofColumn: column),
                    to: nil
                )
                #expect(abs(title.minX - cells.minX) <= 1, "column \(column) at \(level)")
                #expect(abs(title.width - cells.width) <= 1, "column \(column) at \(level)")
            }
        }
    }

    /// Seen live: widths that were only multiplied cut titles to `responseCo…` at 0.8 and to `elap…`
    /// under a sort arrow at 1.75.
    @Test("every header title fits beside a sort arrow at every level")
    func titlesFit() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let surface = fixture.surface
        for level in [0.5, 0.8, 1.75, 3.0] {
            surface.setZoomLevel(level)
            let font = NSFont.systemFont(ofSize: QuickViewTableView.baseHeaderFont.pointSize * level)
            for column in surface.tableView.tableColumns {
                let text = (column.title as NSString).size(withAttributes: [.font: font]).width
                // The arrow is a fixed-size image of about 12 points, with room around it.
                #expect(column.width >= text + 12, "\(column.title) at \(level)")
            }
        }
    }

    @Test("a column somebody widened stays wider, in proportion, through a zoom and back")
    func draggedWidthIsKept() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let surface = fixture.surface
        let column = surface.tableView.tableColumns[3]
        column.width = 260
        surface.setZoomLevel(2)
        #expect(abs(column.width - 520) <= 1)
        surface.setZoomLevel(1)
        #expect(abs(column.width - 260) <= 1)
    }

    @Test("the strip reads at the table's size")
    func stripFollows() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let surface = fixture.surface
        let before = Self.largestFont(in: surface.strip)
        surface.setZoomLevel(2)
        #expect(Self.largestFont(in: surface.strip) == before * 2)
    }

    @Test("⌘+, ⌘− and ⌘0 walk the ladder and come back to the table exactly as it opened")
    func keysWalkTheLadder() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let (preview, surface) = (fixture.preview, fixture.surface)
        let widths = surface.tableView.tableColumns.map(\.width)
        let rowHeight = surface.tableView.rowHeight
        #expect(preview.canZoom(.larger))
        #expect(!preview.canResetZoom)

        preview.zoom(.larger)
        #expect(abs(surface.zoomLevel - 1.1) < 0.001)
        // Down to the ladder's bottom, where columns meet their floor, and back.
        for _ in 0..<10 { preview.zoom(.smaller) }
        #expect(abs(surface.zoomLevel - 0.25) < 0.001)
        #expect(!preview.canZoom(.smaller))
        preview.resetZoom()
        #expect(surface.isAtStartingZoom)
        #expect(surface.tableView.rowHeight == rowHeight)
        for (column, width) in zip(surface.tableView.tableColumns, widths) {
            #expect(abs(column.width - width) <= 1, "\(column.title)")
        }
    }

    @Test("the row at the top of the view stays at the top through a zoom")
    func topRowStaysAtTheTop() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let surface = fixture.surface
        surface.tableView.scrollRowToVisible(surface.tableView.numberOfRows - 1)
        surface.tableView.scrollRowToVisible(40)
        let before = surface.firstVisibleRow
        #expect(before == 40)

        surface.setZoomLevel(2)
        #expect(surface.firstVisibleRow == before)
        surface.setZoomLevel(0.5)
        #expect(surface.firstVisibleRow == before)
    }

    @Test("a new file opens at the table's own size")
    func newFileResetsTheZoom() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let surface = fixture.surface
        surface.setZoomLevel(3)
        let next = try #require(DelimitedTable.parse("a,b\n1,2\n3,4\n"))
        surface.show(next, isTruncated: false)
        #expect(surface.isAtStartingZoom)
        #expect(surface.zoomedCellFont.pointSize == QuickViewTableView.cellFont.pointSize)
        #expect(surface.tableView.rowHeight == QuickViewTableView.baseRowHeight)
    }

    // MARK: - Helpers

    /// A laid-out preview showing the sample, its table, and the directory to remove afterwards.
    private struct Fixture {
        let preview: QuickViewPreviewView
        let surface: QuickViewTableView
        let tree: TempDirectory
    }

    private static func table() async throws -> Fixture {
        let tree = try TempDirectory()
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("zoom.csv", contents: "name,value,note\n\(sample)\n")
        )
        return Fixture(preview: preview, surface: try #require(preview.tableSurface), tree: tree)
    }

    private static func largestFont(in strip: QuickViewRecordStrip) -> CGFloat {
        guard let textView = Self.textView(in: strip), let storage = textView.textStorage else { return 0 }
        var largest: CGFloat = 0
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let font = value as? NSFont { largest = max(largest, font.pointSize) }
        }
        return largest
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }
}
