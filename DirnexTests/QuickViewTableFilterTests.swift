import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Filtering Quick View's table (2026-09-15). Which rows match is `DirnexCore`'s and tested there;
/// what is left is what the bar does to the table on screen — the rows it draws and how it numbers
/// them beside a sort, where the selection and the strip land, and that a new file forgets it all.
/// The keys are `QuickViewTableFilterKeysTests`'.
///
/// Typing is driven through the window's real field editor (`insertText`), so the bar's delegate
/// wiring is under test along with the rules behind it.
@Suite("Quick View table filter")
@MainActor
struct QuickViewTableFilterTests {
    private typealias Fixtures = QuickViewTableFilterFixtures
    private static let sample = Fixtures.sample

    @Test("typing keeps the rows containing the text, each with its number from the file")
    func keepsMatchingRows() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Fixtures.type("CREATE", into: surface)
        #expect(Fixtures.column(surface, 1) == ["cv/create", "attach/create"])
        #expect(Fixtures.column(surface, 0) == ["1", "4"])
        #expect(surface.filterBar.countLabel.stringValue.contains("2"))
        #expect(surface.filterBar.countLabel.stringValue.contains("4"))

        try await Fixtures.type("", into: surface)
        #expect(Fixtures.column(surface, 0) == ["1", "2", "3", "4"])
        #expect(surface.filterBar.countLabel.stringValue.isEmpty)
    }

    @Test("the picker narrows the search to one column")
    func oneColumn() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Fixtures.type("500", into: surface)
        #expect(Fixtures.column(surface, 1).count == 4)

        try await Fixtures.choose(column: 1, in: surface)
        #expect(Fixtures.column(surface, 1) == ["cv/update", "cv/delete"])
        try await Fixtures.choose(column: nil, in: surface)
        #expect(Fixtures.column(surface, 1).count == 4)
    }

    @Test("the picker offers every column, two of the same name included")
    func pickerListsColumns() async throws {
        let fixture = try await Fixtures.table("name,size,name\na,1,b\n")
        defer { fixture.cleanup() }
        let picker = fixture.surface.filterBar.columnPicker
        let columns = picker.itemArray.filter { !$0.isSeparatorItem }.dropFirst()
        #expect(columns.map(\.title) == ["name", "size", "name"])
        #expect(columns.map(\.tag) == [0, 1, 2])
    }

    @Test("a filter keeps the sort's order, and clearing it gives the sorted table back")
    func composesWithSort() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Fixtures.sort(surface, column: 3)
        try await Fixtures.type("cv/", into: surface)
        #expect(Fixtures.column(surface, 3) == ["80", "120", "1500"])
        #expect(Fixtures.column(surface, 0) == ["3", "2", "1"])

        try await Fixtures.type("", into: surface)
        #expect(Fixtures.column(surface, 3) == ["80", "120", "500", "1500"])
        // And a sort made while filtered sorts only what is shown.
        try await Fixtures.type("cv/", into: surface)
        try await Fixtures.sort(surface, column: 1)
        #expect(Fixtures.column(surface, 1) == ["cv/create", "cv/delete", "cv/update"])
    }

    @Test("the selection nobody made goes to the first match, strip and all")
    func automaticSelectionFollowsTheFirstMatch() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Fixtures.type("delete", into: surface)
        #expect(surface.tableView.selectedRow == 0)
        #expect(surface.strip.text.contains("cv/delete"))
    }

    @Test("a row somebody chose stays chosen while it matches, and once the text is cleared")
    func chosenRowIsKept() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        surface.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(surface.strip.text.contains("cv/delete"))

        try await Fixtures.choose(column: 1, in: surface)
        try await Fixtures.type("500", into: surface)
        #expect(Fixtures.selectedLabel(surface) == "cv/delete")
        #expect(surface.tableView.selectedRow == 1)

        try await Fixtures.type("", into: surface)
        #expect(Fixtures.selectedLabel(surface) == "cv/delete")
        #expect(surface.tableView.selectedRow == 2)
    }

    @Test("a chosen row the filter leaves out gives way to the first match")
    func chosenRowLeftOut() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        // Row 1 rather than row 0, which is already selected as the table opens: selecting it again
        // changes nothing, so it would not count as a choice at all (a control found that).
        surface.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(!surface.selectionIsAutomatic)
        try await Fixtures.type("delete", into: surface)
        #expect(Fixtures.selectedLabel(surface) == "cv/delete")
        #expect(surface.selectionIsAutomatic)
    }

    @Test("text found nowhere leaves no rows, an empty strip and a count of none")
    func noMatch() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Fixtures.type("zzz", into: surface)
        #expect(surface.tableView.numberOfRows == 0)
        #expect(surface.strip.isEmpty)
        #expect(surface.filterBar.countLabel.stringValue.contains("0"))
    }

    @Test("a new file opens with the bar away, nothing filtered, and a filter still running dropped")
    func newFileForgetsTheFilter() async throws {
        let fixture = try await Fixtures.table(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        var returned = 0
        surface.returnKeyboard = { returned += 1 }
        try await Fixtures.type("cv/", into: surface)
        #expect(surface.rows.count == 3)

        // A second filter sent off, and the table replaced before it can land.
        let editor = try Fixtures.editor(of: surface)
        editor.insertText("u", replacementRange: editor.selectedRange())
        let stale = try #require(surface.filterTask)
        let next = try #require(DelimitedTable.parse("name,size\nzulu,1\nyankee,2\n"))
        surface.show(next, isTruncated: false)
        #expect(surface.filterBar.isHidden)
        #expect(surface.filterBar.query.isEmpty)
        #expect(returned == 1)
        await stale.value
        #expect(Fixtures.column(surface, 1) == ["zulu", "yankee"])
        #expect(surface.filterMatches == nil)
    }
}

/// The fixtures both table filter suites drive the surface through.
@MainActor
enum QuickViewTableFilterFixtures {
    /// A load-test log's shape: `500` is a response code in one column and milliseconds in another.
    static let sample = """
    label,code,elapsed
    cv/create,200,1500
    cv/update,500,120
    cv/delete,500,80
    attach/create,200,500

    """

    struct Fixture {
        let preview: QuickViewPreviewView
        let surface: QuickViewTableView
        let tree: TempDirectory

        func cleanup() {
            tree.cleanup()
        }
    }

    static func table(_ text: String, function: String = #function) async throws -> Fixture {
        let tree = try TempDirectory()
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("data.csv", contents: text),
            function: function
        )
        return Fixture(preview: preview, surface: try #require(preview.tableSurface), tree: tree)
    }

    /// The field editor typing into the bar, opening the bar first if it is not up.
    static func editor(of surface: QuickViewTableView) throws -> NSTextView {
        if !surface.filterHasKeyboard { surface.beginFiltering() }
        let editor = try #require(surface.window?.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        return editor
    }

    /// Replace the bar's text with `text` as typing would, and wait for the filter to land.
    static func type(_ text: String, into surface: QuickViewTableView) async throws {
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

    /// Pick `column` (a column of the file, `nil` for all of them) and wait for the filter to land.
    static func choose(column: Int?, in surface: QuickViewTableView) async throws {
        let picker = surface.filterBar.columnPicker
        picker.selectItem(withTag: column ?? -1)
        let action = try #require(picker.action)
        #expect(NSApp.sendAction(action, to: picker.target, from: picker))
        await surface.filterTask?.value
    }

    /// Click the header of the table's column `column` (0 is `#`), and wait for the sort to land.
    static func sort(_ surface: QuickViewTableView, column: Int) async throws {
        let prototype = try #require(surface.tableView.tableColumns[column].sortDescriptorPrototype)
        let previous = surface.sortTask
        surface.tableView.sortDescriptors = [prototype]
        if let task = surface.sortTask, task != previous {
            await task.value
        }
    }

    static func column(_ surface: QuickViewTableView, _ column: Int) -> [String] {
        (0..<surface.tableView.numberOfRows).compactMap {
            QuickViewTableFixtures.cellText(surface, row: $0, column: column)
        }
    }

    static func selectedLabel(_ surface: QuickViewTableView) -> String? {
        QuickViewTableFixtures.cellText(surface, row: surface.tableView.selectedRow, column: 1)
    }
}
