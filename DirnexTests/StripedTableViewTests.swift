import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The stripes under a table's last row (2026-10-14). AppKit paints that space with a view of its
/// own, laid from the last row to the table's bottom. On a resize, that view repaints all of itself
/// only when it grows past the largest size it was last drawn at. So a table whose height changed and
/// which then lost rows grew it back inside that size: its bottom band kept the old rows' pixels, and
/// the stripes there ran the wrong way round (``TableFillerRepaint``).
///
/// A test can't see that band. `cacheDisplay` and `CALayer.render(in:)` both redraw from scratch
/// rather than showing what the layer holds, and only the screen shows it (measured with a scratch
/// table, stock against fixed). So this pins what the fix stands on: AppKit's view is one of the
/// table's own subviews, a striped table repaints such a view whole whenever it moves, and every
/// striped table the app builds is one that does.
@Suite("Stripes below the rows")
@MainActor
struct StripedTableViewTests {
    @Test("AppKit lays a view of its own from the last row to the table's bottom")
    func appKitLaysAViewUnderTheRows() throws {
        let fixture = Fixture(rows: 10)
        defer { fixture.window.orderOut(nil) }
        let filler = try #require(fixture.filler)
        let rowHeight = fixture.table.rowHeight + fixture.table.intercellSpacing.height
        #expect(filler.frame.minY == 10 * rowHeight)
        #expect(filler.frame.maxY == fixture.table.bounds.maxY)
    }

    /// AppKit's view is private, so a view of the same kind stands in for it: one that redraws only
    /// when it is told to, as AppKit's own does. Without the fix nothing tells it.
    @Test(
        "a view under the rows is repainted whole when it resizes or only moves",
        arguments: [TableKind.table, .outline, .filePane]
    )
    func movedSubviewIsRepaintedWhole(_ kind: TableKind) {
        let table = kind.make()
        let filler = InvalidationLog(frame: NSRect(x: 0, y: 100, width: 400, height: 200))
        filler.layerContentsRedrawPolicy = .onSetNeedsDisplay
        table.addSubview(filler)

        filler.invalidated = []
        filler.frame = NSRect(x: 0, y: 40, width: 400, height: 260)
        #expect(filler.invalidated.last == filler.bounds)

        // A move alone shifts what the view holds just the same.
        filler.invalidated = []
        filler.setFrameOrigin(NSPoint(x: 0, y: 62))
        #expect(filler.invalidated.last == filler.bounds)

        // Once it is gone, the table stops listening.
        filler.removeFromSuperview()
        filler.invalidated = []
        filler.setFrameOrigin(NSPoint(x: 0, y: 84))
        #expect(filler.invalidated.isEmpty)
    }

    /// Built the way the app builds each one, then searched: a table that sets its stripes is the
    /// thing being checked, so the sheet that forgets to use the class is the one that fails.
    @Test("every striped table the app builds is one that keeps its stripes in step")
    func everyStripedTableIsStriped() throws {
        for (surface, view) in try Self.stripedSurfaces() {
            let striped = Self.tables(in: view).filter(\.usesAlternatingRowBackgroundColors)
            #expect(!striped.isEmpty, "\(surface) shows no striped table")
            for table in striped {
                #expect(
                    table is StripedTableView || table is StripedOutlineView,
                    "\(surface): \(type(of: table))"
                )
            }
        }
    }

    // MARK: - Fixtures

    enum TableKind: CustomStringConvertible {
        case table, outline, filePane

        var description: String {
            switch self {
            case .table: "StripedTableView"
            case .outline: "StripedOutlineView"
            case .filePane: "FileTableView"
            }
        }

        @MainActor
        func make() -> NSTableView {
            let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            return switch self {
            case .table: StripedTableView(frame: frame)
            case .outline: StripedOutlineView(frame: frame)
            case .filePane: FileTableView(frame: frame)
            }
        }
    }

    /// Every surface with a striped table, as the app builds it, named for the failure message.
    private static func stripedSurfaces() throws -> [(String, NSView)] {
        let entry = FileEntry(
            path: .local("/tmp/a.txt"),
            name: "a.txt",
            kind: .file,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
        let left = VFSPath.local("/a")
        let right = VFSPath.local("/b")
        let sync = SyncDirectoriesController(
            leftDir: left,
            rightDir: right,
            backend: Handoff.StubBackend(),
            comparisons: SyncComparison.available(between: left.backend, and: right.backend),
            directions: [.leftToRight]
        )
        let checksums = ChecksumReportController(
            report: ChecksumVerificationReport(
                algorithm: .sha256,
                entries: [ChecksumVerificationEntry(name: "a.txt", status: .ok)]
            ),
            manifestName: "a.sha256"
        )
        let rename = MultiRenameController(items: [entry], existingNamesByDirectory: [:])
        let sharing = AccessControlTableController(
            list: AccessControlList(), kind: .file, canEdit: true
        )
        let attributes = ExtendedAttributeTableController(
            attributes: [ExtendedAttribute(name: "com.example.note", data: Data("x".utf8))]
        )
        return [
            ("Synchronize", sync.view),
            ("Verify Checksums", checksums.view),
            ("Multi-Rename", rename.view),
            ("Get Info ▸ Sharing", sharing.makeView(width: 400)),
            ("Get Info ▸ Attributes", attributes.makeView(width: 400)),
            (
                "Quick View table",
                QuickViewTableView(
                    layoutDefaults: ScratchDefaults.fresh("table"), findOptions: .scratch()
                )
            ),
            (
                "Quick View tree",
                QuickViewTreeView(
                    layoutDefaults: ScratchDefaults.fresh("tree"), findOptions: .scratch()
                )
            )
        ]
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        let own = (view as? NSTableView).map { [$0] } ?? []
        return own + view.subviews.flatMap(tables(in:))
    }

    /// Records every rect it is told to repaint.
    private final class InvalidationLog: NSView {
        var invalidated: [NSRect] = []

        override func setNeedsDisplay(_ invalidRect: NSRect) {
            invalidated.append(invalidRect)
            super.setNeedsDisplay(invalidRect)
        }
    }

    /// A pane's table on screen in a window of its own, with a fixed number of plain rows.
    @MainActor
    private final class Fixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let table = FileTableView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        private let rows: Int

        init(rows: Int) {
            self.rows = rows
            super.init()
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            column.width = 380
            table.addTableColumn(column)
            table.style = .plain
            table.rowSizeStyle = .custom
            table.rowHeight = RowDensity.regular.rowHeight
            table.usesAlternatingRowBackgroundColors = true
            table.dataSource = self
            table.delegate = self
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 560))
            scrollView.documentView = table
            window.contentView = NSView(frame: scrollView.frame)
            window.contentView?.addSubview(scrollView)
            // On screen, or AppKit lays nothing under the rows at all.
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            table.reloadData()
            // Two passes: the first makes the rows, and only the second lays the view under them.
            for _ in 0..<2 {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }

        /// The view AppKit lays under the last row: the table's one visible subview that is not a row.
        var filler: NSView? {
            table.subviews.first { !($0 is NSTableRowView) && !$0.isHidden }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            NSTextField(labelWithString: "row \(row)")
        }
    }
}
