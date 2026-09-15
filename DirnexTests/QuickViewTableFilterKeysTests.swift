import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The table filter's keys, its place on the surface, and the command that opens it (2026-09-15):
/// what Esc, Return, Tab and the arrows do while the keyboard is in the text, that the bar takes its
/// room from the table, that the window can tell typing there from any other focus in a preview, and
/// that View ▸ Filter Table reaches it on ⌥⌘F.
@Suite("Quick View table filter keys")
@MainActor
struct QuickViewTableFilterKeysTests {
    private typealias Fixtures = QuickViewTableFilterFixtures
    private static let sample = Fixtures.sample

    @Test("Esc clears the text, and a second Esc puts the bar away and hands the keyboard back")
    func escape() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        var returned = 0
        surface.returnKeyboard = { returned += 1 }
        try await Fixtures.type("delete", into: surface)

        try Fixtures.editor(of: surface).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(surface.filterBar.query.isEmpty)
        #expect(!surface.filterBar.isHidden)
        #expect(surface.rows.count == 4)
        #expect(returned == 0)

        try Fixtures.editor(of: surface).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(surface.filterBar.isHidden)
        #expect(returned == 1)
    }

    @Test("Return and Tab hand the keyboard back and keep the filter")
    func returnKeepsTheFilter() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        var returned = 0
        surface.returnKeyboard = { returned += 1 }
        try await Fixtures.type("cv/", into: surface)
        try Fixtures.editor(of: surface).doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(returned == 1)
        #expect(surface.rows.count == 3)
        #expect(!surface.filterBar.isHidden)

        surface.beginFiltering()
        try Fixtures.editor(of: surface).doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(returned == 2)
    }

    @Test("↑ and ↓ in the text step through the rows the filter left, the strip following")
    func arrowsStepThroughMatches() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Fixtures.type("cv/", into: surface)
        #expect(surface.tableView.selectedRow == 0)

        let down = #selector(NSResponder.moveDown(_:))
        let up = #selector(NSResponder.moveUp(_:))
        try Fixtures.editor(of: surface).doCommand(by: down)
        try Fixtures.editor(of: surface).doCommand(by: down)
        #expect(Fixtures.selectedLabel(surface) == "cv/delete")
        #expect(surface.strip.text.contains("cv/delete"))
        try Fixtures.editor(of: surface).doCommand(by: down)
        #expect(surface.tableView.selectedRow == 2)
        try Fixtures.editor(of: surface).doCommand(by: up)
        #expect(Fixtures.selectedLabel(surface) == "cv/update")
        // Still typing: the arrows moved rows, not the keyboard.
        #expect(surface.filterHasKeyboard)
    }

    @Test("the bar takes its room from the table, above it")
    func barSitsAboveTheTable() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        let fullHeight = surface.scrollView.frame.height
        surface.beginFiltering()
        surface.layoutSubtreeIfNeeded()
        let bar = surface.filterBar.frame
        let table = surface.scrollView.frame
        #expect(abs(table.height - (fullHeight - QuickViewTableFilterBar.height)) <= 1)
        let barIsAbove = surface.isFlipped ? bar.maxY <= table.minY + 0.5 : bar.minY >= table.maxY - 0.5
        #expect(barIsAbove)
        #expect(surface.roomBelowFilterBar == surface.bounds.height - QuickViewTableFilterBar.height)
        // A strip dragged as tall as it goes still leaves the table its header and a couple of rows,
        // under the bar rather than under the surface's top.
        surface.resizeStrip(to: 5000)
        surface.layoutSubtreeIfNeeded()
        #expect(abs(surface.scrollView.frame.height - QuickViewTableView.minimumTableHeight) <= 1)
        surface.fitStripToRow()

        surface.endFiltering()
        surface.layoutSubtreeIfNeeded()
        #expect(abs(surface.scrollView.frame.height - fullHeight) <= 1)
    }

    /// The window's key monitor hands a bare arrow from a focused preview back to the file list, and
    /// re-asserts the file list after every delivery; both have to leave somebody typing alone.
    @Test("typing in the bar is told apart from every other focus inside a preview")
    func typingIsToldApart() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let (preview, surface) = (fixture.preview, fixture.surface)
        let window = try #require(surface.window)
        surface.beginFiltering()
        let editor = try Fixtures.editor(of: surface)
        #expect(QuickViewPreviewView.hasFocus(editor, among: [preview]))
        #expect(QuickViewPreviewView.isTypingInField(editor, among: [preview]))
        #expect(!QuickViewPreviewView.isTypingInField(editor, among: [nil]))

        window.makeFirstResponder(surface.tableView)
        #expect(!QuickViewPreviewView.isTypingInField(window.firstResponder, among: [preview]))
        #expect(QuickViewPreviewView.hasFocus(window.firstResponder, among: [preview]))
        #expect(!surface.filterHasKeyboard)
    }

    @Test("View ▸ Filter Table reaches the window's action on ⌥⌘F, and only a table can be filtered")
    func command() async throws {
        let action = #selector(BrowserWindowController.filterQuickViewTable(_:))
        #expect(CommandBinding.selector(for: "view.quickViewFilterTable") == action)
        let items = QuickViewZoomFixtures.flatten(
            MainMenuBuilder.build(bindings: KeyBindingStore(defaults: ScratchDefaults.fresh()))
        )
        let item = try #require(items.first { $0.action == action })
        #expect(item.keyEquivalent == "f")
        #expect(item.keyEquivalentModifierMask == [.command, .option])

        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        #expect(fixture.preview.filterableTable === fixture.surface)
        let text = try await QuickViewTableFixtures.loaded(
            try fixture.tree.write("notes.txt", contents: "plain text\n")
        )
        #expect(text.filterableTable == nil)
    }
}
