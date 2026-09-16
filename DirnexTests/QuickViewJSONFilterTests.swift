import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Filtering Quick View's JSON tree (2026-09-15). Which values match, and which rows a filtered tree
/// lists and opens, is `DirnexCore`'s and tested there; what is left is what the bar does to the tree
/// on screen — the rows, the picker, where the selection lands, what clearing gives back — and that the
/// window's command reaches it. The bar's keys are shared with the table's (`QuickViewFilterHost`).
@Suite("Quick View JSON filter")
@MainActor
struct QuickViewJSONFilterTests {
    private typealias Fixtures = QuickViewJSONFilterFixtures

    @Test(
        "typing keeps the values containing the text and the way down to them, the first match chosen"
    )
    func keepsMatches() async throws {
        let fixture = try await Fixtures.tree()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Fixtures.type("es2022", into: surface)
        #expect(Fixtures.rows(surface) == ["compilerOptions {3}", "target \"ES2022\""])
        #expect(surface.outlineView.selectedRow == 1)
        #expect(surface.strip.text.contains("$.compilerOptions.target"))
        #expect(surface.filterBar.countLabel.stringValue.contains("9"))

        try await Fixtures.type("", into: surface)
        #expect(Fixtures.rows(surface).count == 8)
        #expect(surface.filterBar.countLabel.stringValue.isEmpty)
    }

    /// The user's choice: finding `paths` finds what it holds.
    @Test("a matched container keeps its contents, closed, and opens to all of them")
    func containerKeepsItsContents() async throws {
        let fixture = try await Fixtures.tree()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Fixtures.type("paths", into: surface)
        #expect(Fixtures.rows(surface) == ["compilerOptions {3}", "paths {1}"])
        let paths = try #require(surface.outlineView.item(atRow: 1))
        #expect(surface.outlineView.isExpandable(paths))
        #expect(!surface.outlineView.isItemExpanded(paths))
        surface.outlineView.expandItem(paths)
        #expect(Fixtures.rows(surface) == ["compilerOptions {3}", "paths {1}", "@/* [1]"])
    }

    @Test("the picker narrows the search to keys or to values")
    func scopes() async throws {
        let fixture = try await Fixtures.tree()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        let everywhere = [
            "compilerOptions {3}", "paths {1}", "@/* [1]", "[0] \"./src/*\"", "include [1]",
            "[0] \"src\""
        ]
        try await Fixtures.type("src", into: surface)
        #expect(Fixtures.rows(surface) == everywhere)

        try await Fixtures.choose(.keys, in: surface)
        #expect(Fixtures.rows(surface).isEmpty)
        #expect(surface.strip.isEmpty)
        try await Fixtures.choose(.values, in: surface)
        #expect(Fixtures.rows(surface) == everywhere)
    }

    @Test(
        "clearing the text gives back the rows that were open, with the chosen value opened into view"
    )
    func clearingGivesTheTreeBack() async throws {
        let fixture = try await Fixtures.tree()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        let outline = surface.outlineView
        try outline.collapseItem(#require(outline.item(atRow: 6)))
        try outline.collapseItem(#require(outline.item(atRow: 0)))
        #expect(Fixtures.rows(surface) == ["compilerOptions {3}", "include [1]"])

        try await Fixtures.type("strict", into: surface)
        #expect(Fixtures.rows(surface) == ["compilerOptions {3}", "strict true"])
        #expect(outline.selectedRow == 1)

        try await Fixtures.type("", into: surface)
        #expect(Fixtures.rows(surface) == [
            "compilerOptions {3}", "target \"ES2022\"", "strict true", "paths {1}", "include [1]"
        ])
        #expect(outline.selectedRow == 2)
        #expect(surface.strip.text.contains("$.compilerOptions.strict"))
    }

    @Test(
        "Esc clears the text and then puts the bar away; Return keeps the filter and hands the keyboard back"
    )
    func keys() async throws {
        let fixture = try await Fixtures.tree()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        var returned = 0
        surface.returnKeyboard = { returned += 1 }
        try await Fixtures.type("src", into: surface)
        try Fixtures.editor(of: surface).doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(returned == 1)
        #expect(Fixtures.rows(surface).count == 6)
        #expect(!surface.filterBar.isHidden)

        try Fixtures.editor(of: surface).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(surface.filterBar.query.isEmpty)
        #expect(Fixtures.rows(surface).count == 8)
        try Fixtures.editor(of: surface).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(surface.filterBar.isHidden)
        #expect(returned == 2)
    }

    @Test("another file puts the filter away and opens unfiltered")
    func newFileForgetsTheFilter() async throws {
        let fixture = try await Fixtures.tree()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Fixtures.type("strict", into: surface)
        fixture.preview.show(
            try fixture.tree.write("second.json", contents: #"{"b": 1, "strict": 2}"#),
            style: .rendered
        )
        await QuickViewJSONFixtures.settle { Fixtures.rows(surface) == ["b 1", "strict 2"] }
        #expect(Fixtures.rows(surface) == ["b 1", "strict 2"])
        #expect(surface.filterBar.isHidden)
        #expect(surface.filterBar.query.isEmpty)
        #expect(surface.filter == nil)
    }

    @Test(
        "View ▸ Filter reaches the tree, a JSON file of records filters as a table, and text as neither"
    )
    func filterableSurfaces() async throws {
        let fixture = try await Fixtures.tree()
        defer { fixture.cleanup() }
        #expect(fixture.preview.filterableSurface === fixture.surface)

        let records = try await QuickViewTableFixtures.loaded(
            try fixture.tree.write("events.jsonl", contents: QuickViewJSONPreviewTests.lines)
        )
        #expect(records.filterableSurface === records.tableSurface)
        let text = try await QuickViewTableFixtures.loaded(
            try fixture.tree.write("notes.txt", contents: "plain text\n")
        )
        #expect(text.filterableSurface == nil)
    }
}

/// A JSON tree in a window, and the filter bar driven as typing drives it.
@MainActor
enum QuickViewJSONFilterFixtures {
    struct Fixture {
        let preview: QuickViewPreviewView
        let surface: QuickViewTreeView
        let tree: TempDirectory

        func cleanup() {
            tree.cleanup()
        }
    }

    /// `QuickViewJSONPreviewTests.config` in a tree, opened whole: eight rows over nine values.
    static func tree(function: String = #function) async throws -> Fixture {
        let tree = try TempDirectory()
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("tsconfig.json", contents: QuickViewJSONPreviewTests.config),
            function: function
        )
        return Fixture(preview: preview, surface: try #require(preview.treeSurface), tree: tree)
    }

    static func rows(_ surface: QuickViewTreeView) -> [String] {
        QuickViewJSONFixtures.rows(surface)
    }

    /// The field editor typing into the bar, opening the bar first if it is not up.
    static func editor(of surface: QuickViewTreeView) throws -> NSTextView {
        if !surface.filterHasKeyboard { surface.beginFiltering() }
        let editor = try #require(surface.window?.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        return editor
    }

    /// Replace the bar's text with `text` as typing would, and wait for the filter to land.
    static func type(_ text: String, into surface: QuickViewTreeView) async throws {
        let editor = try editor(of: surface)
        editor.selectAll(nil)
        if text.isEmpty {
            editor.deleteBackward(nil)
        } else {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        #expect(surface.filterBar.query == text)
        await surface.filterTask?.value
    }

    /// Pick `scope` and wait for the filter to land.
    static func choose(_ scope: TreeFilterScope, in surface: QuickViewTreeView) async throws {
        let picker = surface.filterBar.columnPicker
        picker.selectItem(withTag: scope.rawValue)
        let action = try #require(picker.action)
        #expect(NSApp.sendAction(action, to: picker.target, from: picker))
        await surface.filterTask?.value
    }
}
