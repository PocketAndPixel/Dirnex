import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What a JSON preview puts on screen — the tree, the strip, a list of records in the table — and the
/// rules the tree shares with the other backends: it keeps the mouse, it zooms, and it is put away
/// when another file arrives (2026-09-15).
@Suite("Quick View JSON surface")
@MainActor
struct QuickViewJSONSurfaceTests {
    private func loaded(
        _ name: String,
        _ contents: String,
        in tree: TempDirectory,
        style: QuickViewRenderStyle = .rendered,
        function: String = #function
    ) async throws -> QuickViewPreviewView {
        try await QuickViewTableFixtures.loaded(
            try tree.write(name, contents: contents),
            style: style,
            function: function
        )
    }

    // MARK: - What reaches the screen

    @Test("a JSON file fills the tree in the file's order, with its small containers open")
    func treeReachesTheScreen() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("tsconfig.json", QuickViewJSONPreviewTests.config, in: tree)
        let surface = try #require(preview.jsonTreeSurface)
        #expect(!surface.isHidden)
        #expect(preview.tableSurface?.isHidden != false)
        #expect(preview.textSurface?.isHidden != false)
        #expect(QuickViewJSONFixtures.rows(surface) == [
            "compilerOptions {3}", "target \"ES2022\"", "strict true", "paths {1}", "@/* [1]",
            "[0] \"./src/*\"", "include [1]", "[0] \"src\""
        ])
        #expect(surface.outlineView.tableColumns.map(\.title) == [
            QuickViewJSONTreeView.keyTitle, QuickViewJSONTreeView.valueTitle
        ])
    }

    @Test(
        "the first row is selected on arrival, and the strip shows the selected value's path and text"
    )
    func stripFollowsSelection() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("tsconfig.json", QuickViewJSONPreviewTests.config, in: tree)
        let surface = try #require(preview.jsonTreeSurface)
        #expect(surface.outlineView.selectedRow == 0)
        #expect(surface.strip.text.contains("$.compilerOptions"))
        #expect(surface.strip.text.contains("\"target\": \"ES2022\""))
        // Every line of a value written out sits under its first line, not at the strip's edge under
        // the names — which is where the second line and on started, seen live on this very row.
        let record = surface.strip.attributedText
        let text = record.string as NSString
        let first = record.attribute(
            .paragraphStyle,
            at: text.range(of: "{").location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let second = record.attribute(
            .paragraphStyle,
            at: text.range(of: "\"target\"").location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect((second?.firstLineHeadIndent ?? 0) > 0)
        #expect(second?.firstLineHeadIndent == first?.headIndent)

        surface.outlineView.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        #expect(surface.strip.text.contains(#"$.compilerOptions.paths["@/*"]"#))
        surface.outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(surface.strip.text.contains("ES2022"))
        #expect(!surface.strip.text.contains("\"ES2022\""))

        surface.outlineView.deselectAll(nil)
        #expect(surface.strip.isEmpty)
    }

    @Test("⌘C copies the selected value: a string's text, and a container as indented JSON")
    func copiesTheValue() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("tsconfig.json", QuickViewJSONPreviewTests.config, in: tree)
        let outline = try #require(preview.jsonTreeSurface?.outlineView)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dirnex-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        outline.pasteboard = pasteboard

        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        outline.copy(nil)
        #expect(pasteboard.string(forType: .string) == "ES2022")
        outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        outline.copy(nil)
        #expect(pasteboard.string(forType: .string) == "{\n  \"@/*\": [\n    \"./src/*\"\n  ]\n}")
    }

    @Test("a container bigger than the opening budget opens closed, and its small siblings open")
    func bigContainersOpenClosed() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let numbers = (0..<500).map(String.init).joined(separator: ",")
        let preview = try await loaded(
            "big.json",
            #"{"big": [\#(numbers)], "small": {"x": 1}}"#,
            in: tree
        )
        let surface = try #require(preview.jsonTreeSurface)
        #expect(QuickViewJSONFixtures.rows(surface) == ["big [500]", "small {1}", "x 1"])
    }

    /// The user's choice of shape: a list of like objects reads as a CSV does.
    @Test(
        "a JSON Lines file of records opens in the table, the tree put away, and the header says Table"
    )
    func recordsOpenInTheTable() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("events.jsonl", QuickViewJSONPreviewTests.lines, in: tree)
        let table = try #require(preview.tableSurface)
        #expect(!table.isHidden)
        #expect(table.tableView.tableColumns.map(\.title) == ["#", "role", "content", "ts"])
        #expect(table.tableView.numberOfRows == 2)
        #expect(preview.jsonTreeSurface?.isHidden != false)
        #expect(preview.filterableTable != nil)
        let caption = QuickViewCaption(
            name: "events.jsonl",
            position: 1,
            count: 1,
            style: .rendered,
            styleKind: .json
        )
        #expect(preview.captionForHeader(caption)?.styleKind == .table)
    }

    @Test("a tree's header keeps its own name, and a file that is not JSON after all shows as text")
    func treeCaptionAndFallback() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("tsconfig.json", QuickViewJSONPreviewTests.config, in: tree)
        let caption = QuickViewCaption(
            name: "a",
            position: 1,
            count: 1,
            style: .rendered,
            styleKind: .json
        )
        #expect(preview.captionForHeader(caption)?.styleKind == .json)

        let broken = try await loaded("broken.json", #"{"a": "#, in: tree)
        #expect(broken.jsonTreeSurface?.isHidden != false)
        #expect(broken.textSurface?.isHidden == false)
    }

    @Test("the same JSON file in the source style is its text")
    func sourceIsText() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded(
            "tsconfig.json",
            QuickViewJSONPreviewTests.config,
            in: tree,
            style: .source
        )
        #expect(preview.jsonTreeSurface?.isHidden != false)
        let text = try #require(QuickViewTableFixtures.documentTextView(of: preview))
        #expect(text.string.contains("compilerOptions"))
    }

    // MARK: - Sharing the surface

    @Test("a click over the tree reaches the tree, not the surface")
    func treeKeepsTheMouse() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("tsconfig.json", QuickViewJSONPreviewTests.config, in: tree)
        let surface = try #require(preview.jsonTreeSurface)
        let point = surface.convert(
            NSPoint(x: 60, y: surface.bounds.height - 40),
            to: preview.superview
        )
        let hit = try #require(preview.hitTest(point))
        #expect(hit !== preview)
        #expect(hit.isDescendant(of: surface))
    }

    @Test(
        "a second JSON file keeps the tree up, records swap it for the table, and other files put it away"
    )
    func standsDown() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("tsconfig.json", QuickViewJSONPreviewTests.config, in: tree)
        let surface = try #require(preview.jsonTreeSurface)

        preview.show(try tree.write("second.json", contents: #"{"b": 1}"#), style: .rendered)
        #expect(!surface.isHidden)
        await QuickViewJSONFixtures.settle { QuickViewJSONFixtures.rows(surface) == ["b 1"] }
        #expect(QuickViewJSONFixtures.rows(surface) == ["b 1"])

        preview.show(
            try tree.write("events.jsonl", contents: QuickViewJSONPreviewTests.lines),
            style: .rendered
        )
        await QuickViewJSONFixtures.settle { preview.tableSurface?.table != nil }
        #expect(surface.isHidden)
        #expect(preview.tableSurface?.isHidden == false)

        preview.show(try tree.write("third.json", contents: #"{"c": [1]}"#), style: .rendered)
        await QuickViewJSONFixtures.settle { surface.document != nil }
        #expect(!surface.isHidden)
        #expect(preview.tableSurface?.isHidden != false)

        preview.show(try tree.write("notes.txt", contents: "hello\n"), style: .rendered)
        #expect(surface.isHidden)
        #expect(surface.document == nil)
    }

    @Test("⌘+ zooms the tree and keeps what is open and selected, and ⌘0 puts it back")
    func zooms() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await loaded("tsconfig.json", QuickViewJSONPreviewTests.config, in: tree)
        let surface = try #require(preview.jsonTreeSurface)
        let rowHeight = surface.outlineView.rowHeight
        let rows = surface.outlineView.numberOfRows
        #expect(preview.canZoom(.larger))
        #expect(!preview.canResetZoom)

        preview.zoom(.larger)
        #expect(surface.zoomLevel > 1)
        #expect(surface.outlineView.rowHeight > rowHeight)
        #expect(surface.outlineView.numberOfRows == rows)
        #expect(surface.outlineView.selectedRow == 0)
        #expect(preview.canResetZoom)

        preview.resetZoom()
        #expect(surface.isAtStartingZoom)
        #expect(surface.outlineView.rowHeight == rowHeight)
    }
}

/// The parts of a JSON tree the suites read.
@MainActor
enum QuickViewJSONFixtures {
    /// Every row as `key value`, the text its two cells draw, through the tree's own delegate.
    static func rows(_ surface: QuickViewJSONTreeView) -> [String] {
        (0..<surface.outlineView.numberOfRows).map { row in
            guard let item = surface.outlineView.item(atRow: row) else { return "" }
            return "\(text(surface, column: 0, item: item)) \(text(surface, column: 1, item: item))"
        }
    }

    private static func text(_ surface: QuickViewJSONTreeView, column: Int, item: Any) -> String {
        let tableColumn = surface.outlineView.tableColumns[column]
        let view = surface.outlineView(surface.outlineView, viewFor: tableColumn, item: item)
        return (view as? NSTableCellView)?.textField?.stringValue ?? ""
    }

    /// Wait, by sleeping rather than spinning the run loop, for a detached read to land.
    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
