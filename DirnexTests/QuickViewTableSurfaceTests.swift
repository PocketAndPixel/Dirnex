import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What a CSV preview puts on screen — the table, the strip, the colored source — and the rules the
/// table shares with the other backends: it keeps the mouse, it is put away when another file
/// arrives, and a wide one pans rather than turning the page (2026-09-15).
@Suite("Quick View table surface")
@MainActor
struct QuickViewTableSurfaceTests {
    // MARK: - What reaches the screen

    @Test("a CSV in the rendered style fills the table, titled by its header row")
    func tableReachesTheScreen() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("people.csv", contents: QuickViewTablePreviewTests.sample)
        )
        let surface = try #require(preview.tableSurface)
        #expect(!surface.isHidden)
        #expect(preview.textSurface?.isHidden != false)
        #expect(surface.tableView.numberOfRows == 3)
        #expect(surface.tableView.tableColumns.map(\.title) == ["#", "id", "name", "note"])
        let note = try #require(QuickViewTableFixtures.cellText(surface, row: 1, column: 3))
        #expect(note == "said \"hi\"")
    }

    /// Found live on the first run: the table opened with row 1 under its own column header, because
    /// scrolling the document to its origin ignores the header floating over it. The selected row was
    /// the one row nobody could see. It takes a surface already laid out and a full-size content view
    /// (the browser window's) to reproduce; in a plain window the header takes a strip of its own.
    @Test("the table opens at its first row, not scrolled under its own header")
    func opensAtTheFirstRow() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let rows = (1...80).map { "\($0),name\($0),note" }.joined(separator: "\n")
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("long.csv", contents: "id,name,note\n\(rows)\n")
        )
        let surface = try #require(preview.tableSurface)
        // The second file is the one that lands in a surface already laid out — the live case.
        preview.show(try tree.write("second.csv", contents: "a,b,c\n\(rows)\n"), style: .rendered)
        for _ in 0..<400 where !surface.tableView.tableColumns.contains(where: { $0.title == "a" }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        surface.superview?.layoutSubtreeIfNeeded()
        let clip = surface.scrollView.contentView
        let visible = surface.tableView.rows(in: clip.documentVisibleRect)
        #expect(visible.location == 0)
        #expect(surface.tableView.rect(ofRow: 0).minY >= clip.documentVisibleRect.minY)
    }

    @Test("the first row is selected on arrival, and the strip shows the selected row whole")
    func stripFollowsSelection() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("people.csv", contents: QuickViewTablePreviewTests.sample)
        )
        let surface = try #require(preview.tableSurface)
        #expect(surface.tableView.selectedRow == 0)
        #expect(surface.strip.text.contains("Paris, France"))
        #expect(surface.strip.text.contains("name"))

        surface.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(surface.strip.text.contains("said \"hi\""))
        #expect(!surface.strip.text.contains("Paris"))

        surface.tableView.deselectAll(nil)
        #expect(surface.strip.isEmpty)
    }

    @Test("⌘C puts the selected rows on the pasteboard as tab-separated text")
    func copiesSelectedRows() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("people.csv", contents: QuickViewTablePreviewTests.sample)
        )
        let tableView = try #require(preview.tableSurface?.tableView)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dirnex-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        tableView.pasteboard = pasteboard

        tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        tableView.copy(nil)
        #expect(pasteboard.string(forType: .string) == "1\tAlice\tParis, France\n3\tCarol\tplain")
        #expect(pasteboard.string(forType: .tabularText) == pasteboard.string(forType: .string))
    }

    @Test("the same CSV in the source style is text, colored by column")
    func sourceIsColoredByColumn() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("people.csv", contents: QuickViewTablePreviewTests.sample)
        let preview = try await QuickViewTableFixtures.loaded(url, style: .source)
        #expect(preview.tableSurface?.isHidden != false)
        let textView = try #require(QuickViewTableFixtures.documentTextView(of: preview))
        let storage = try #require(textView.textStorage)
        let nameColumn = (textView.string as NSString).range(of: "Alice")
        let noteColumn = (textView.string as NSString).range(of: "plain")
        let name = storage.attribute(.foregroundColor, at: nameColumn.location, effectiveRange: nil)
            as? NSColor
        let note = storage.attribute(.foregroundColor, at: noteColumn.location, effectiveRange: nil)
            as? NSColor
        #expect(name == DelimitedColumnTheme.color(forColumn: 1))
        #expect(note == DelimitedColumnTheme.color(forColumn: 2))
        #expect(name != note)
    }

    @Test("a file that is not a table after all shows as text")
    func malformedFallsBackToText() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("broken.csv", contents: "a,b\n\"never closed,1\n2,3\n")
        )
        #expect(preview.tableSurface?.isHidden != false)
        #expect(preview.textSurface?.isHidden == false)
    }

    // MARK: - Sharing the surface

    @Test("a click over the table reaches the table, not the surface")
    func tableKeepsTheMouse() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("people.csv", contents: QuickViewTablePreviewTests.sample)
        )
        let surface = try #require(preview.tableSurface)
        let point = surface.convert(
            NSPoint(x: 60, y: surface.bounds.height - 40),
            to: preview.superview
        )
        let hit = try #require(preview.hitTest(point))
        #expect(hit !== preview)
        #expect(hit.isDescendant(of: surface))
    }

    @Test("another file puts the table away, and a second CSV keeps it up")
    func standsDownForOtherFiles() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("people.csv", contents: QuickViewTablePreviewTests.sample)
        )
        let surface = try #require(preview.tableSurface)

        preview.show(try tree.write("other.csv", contents: "x,y\n1,2\n"), style: .rendered)
        #expect(!surface.isHidden)

        preview.show(try tree.write("notes.txt", contents: "hello\n"), style: .rendered)
        #expect(surface.isHidden)
        #expect(surface.table == nil)
    }

    @Test("a table wider than the surface pans sideways, and a narrow one leaves the swipe alone")
    func wideTablesPan() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let narrow = try await QuickViewTableFixtures.loaded(
            try tree.write("narrow.csv", contents: "a,b\n1,2\n3,4\n")
        )
        #expect(!narrow.consumesHorizontalScroll)

        let longValue = String(repeating: "wide value ", count: 20)
        let header = (0..<6).map { "column\($0)" }.joined(separator: ",")
        let row = (0..<6).map { _ in longValue }.joined(separator: ",")
        let wideFile = try tree.write("wide.csv", contents: "\(header)\n\(row)\n\(row)\n")
        let wide = try await QuickViewTableFixtures.loaded(wideFile)
        #expect(wide.consumesHorizontalScroll)
    }
}

/// A table preview in a window, and the parts of it the table suites read.
@MainActor
enum QuickViewTableFixtures {
    /// Every fixture window, kept for the life of the test process. Without this the window goes the
    /// moment `loaded` returns and every step after it runs on a surface in no window — which hides
    /// exactly what a window changes, the header floating over the rows (found when the zoom's
    /// top-row test passed windowless). Kept rather than closed, since tearing a window down while
    /// AppKit is still settling it crashes a later test (docs/NOTES.md ▸ Testing).
    private static var windows: [NSWindow] = []

    /// A surface in a window, showing `url`, awaited until a table or a text view has landed —
    /// polling with `Task.sleep` rather than spinning the run loop, which cannot land a detached
    /// read (docs/NOTES.md ▸ Testing).
    static func loaded(
        _ url: URL,
        style: QuickViewRenderStyle = .rendered
    ) async throws -> QuickViewPreviewView {
        let preview = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .none)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        windows.append(window)
        let container = try #require(window.contentView)
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        // Laid out before the file is shown, as a surface already on screen is: a table landing in a
        // view that has no frame yet is scrolled by AppKit's first layout, which hides the bug below.
        container.layoutSubtreeIfNeeded()
        preview.show(url, style: style)
        for _ in 0..<400 {
            if preview.tableSurface?.table != nil { break }
            if let text = documentTextView(of: preview), !text.string.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        container.layoutSubtreeIfNeeded()
        return preview
    }

    static func documentTextView(of preview: QuickViewPreviewView) -> NSTextView? {
        guard let surface = preview.textSurface, !surface.isHidden else { return nil }
        return (surface.interactiveSubtree as? NSScrollView)?.documentView as? NSTextView
    }

    /// The text a cell draws, through the table's own delegate. `column` is the table's own column
    /// index, so the row-number column is 0 and the file's first column is 1.
    static func cellText(_ surface: QuickViewTableView, row: Int, column: Int) -> String? {
        let tableColumn = surface.tableView.tableColumns[column]
        let view = surface.tableView(surface.tableView, viewFor: tableColumn, row: row) as? NSTableCellView
        return view?.textField?.stringValue
    }
}
