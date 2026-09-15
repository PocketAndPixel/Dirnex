import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Sorting Quick View's table by its column headers (2026-09-15). The order itself is `DirnexCore`'s
/// and tested there; what is left is what a header click does to the table on screen — which rows
/// it draws and how it numbers them, where the selection and the strip end up, and that the file's
/// order is one click away.
///
/// A click is driven by setting the table's sort descriptors to the column's prototype, which is what
/// `NSTableHeaderView` does with one; the selector test pins that AppKit can reach the handler at all.
@Suite("Quick View table sorting")
@MainActor
struct QuickViewTableSortingTests {
    private static let sample = """
    name,size
    delta,10
    alpha,9
    charlie,100
    bravo,-2

    """

    @Test("AppKit can reach the sort handler")
    func handlerIsReachable() {
        let surface = QuickViewTableView(layoutDefaults: ScratchDefaults.fresh())
        #expect(surface.responds(to: NSSelectorFromString("tableView:sortDescriptorsDidChange:")))
    }

    @Test(
        "a header click sorts by value, keeps each row's number from the file, and a second reverses"
    )
    func sortsAndReverses() async throws {
        let (surface, cleanup) = try await Self.table(Self.sample)
        defer { cleanup() }
        try await Self.click(surface, column: 2)
        #expect(Self.column(surface, 2) == ["-2", "9", "10", "100"])
        #expect(Self.column(surface, 0) == ["4", "2", "1", "3"])

        try await Self.click(surface, column: 2)
        #expect(Self.column(surface, 2) == ["100", "10", "9", "-2"])
    }

    @Test("the # column goes back to the file's order, or reverses it")
    func rowNumberColumnRestoresFileOrder() async throws {
        let (surface, cleanup) = try await Self.table(Self.sample)
        defer { cleanup() }
        try await Self.click(surface, column: 1)
        #expect(Self.column(surface, 1) == ["alpha", "bravo", "charlie", "delta"])

        try await Self.click(surface, column: 0)
        #expect(Self.column(surface, 1) == ["delta", "alpha", "charlie", "bravo"])
        try await Self.click(surface, column: 0)
        #expect(Self.column(surface, 1) == ["bravo", "charlie", "alpha", "delta"])
    }

    @Test("the selection the table opened with goes to the top of the new order, strip and all")
    func automaticSelectionFollowsTheTop() async throws {
        let (surface, cleanup) = try await Self.table(Self.sample)
        defer { cleanup() }
        try await Self.click(surface, column: 1)
        #expect(surface.tableView.selectedRow == 0)
        #expect(surface.strip.text.contains("alpha"))
    }

    @Test("a row somebody selected stays selected through a sort, and the strip keeps showing it")
    func chosenSelectionIsKept() async throws {
        let (surface, cleanup) = try await Self.table(Self.sample)
        defer { cleanup() }
        surface.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(surface.strip.text.contains("charlie"))

        try await Self.click(surface, column: 2)
        let selected = surface.tableView.selectedRow
        #expect(QuickViewTableFixtures.cellText(surface, row: selected, column: 1) == "charlie")
        #expect(selected == 3)
        #expect(surface.strip.text.contains("charlie"))
    }

    @Test("⌘C copies the selected rows in the order they are shown")
    func copiesInDisplayedOrder() async throws {
        let (surface, cleanup) = try await Self.table(Self.sample)
        defer { cleanup() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dirnex-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        surface.tableView.pasteboard = pasteboard

        try await Self.click(surface, column: 1)
        surface.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        surface.tableView.copy(nil)
        #expect(pasteboard.string(forType: .string) == "alpha\t9\nbravo\t-2")
    }

    @Test("a new file opens unsorted, and a sort still running for the old one is dropped")
    func newFileResetsTheSort() async throws {
        let (surface, cleanup) = try await Self.table(Self.sample)
        defer { cleanup() }
        try await Self.click(surface, column: 1)

        // A second sort sent off, and the table replaced before it can land. The test awaits that
        // sort's own task rather than a fixed delay: a delay here read as a pass with the guard
        // against a stale sort removed (a control found it).
        let prototype = try #require(surface.tableView.tableColumns[2].sortDescriptorPrototype)
        surface.tableView.sortDescriptors = [prototype]
        let stale = try #require(surface.sortTask)
        let next = try #require(DelimitedTable.parse("name,size\nzulu,1\nyankee,2\n"))
        surface.show(next, isTruncated: false)
        #expect(surface.tableView.sortDescriptors.isEmpty)
        await stale.value
        #expect(Self.column(surface, 1) == ["zulu", "yankee"])
        #expect(surface.sortOrder == nil)
    }

    /// Found live on a load-test log: `bytes` was sized from its first hundred values, and sorting it
    /// brought a larger one to the top drawn as `1374…`.
    @Test("a column of numbers is wide enough for its longest value, however far down it is")
    func numericColumnsFitTheirLongestValue() async throws {
        // Past the sample: the width budget spreads 2 000 values over the columns, so two columns
        // sample the first 1 000 rows, and a fixture shorter than that tests nothing (a control found it).
        let rows = (1...1200).map { "row\($0),\($0 % 9)" }.joined(separator: "\n")
        let (surface, cleanup) = try await Self.table("name,bytes\n\(rows)\nlast,12345678901234\n")
        defer { cleanup() }
        let column = surface.tableView.tableColumns[2]
        let needed = ("12345678901234" as NSString)
            .size(withAttributes: [.font: QuickViewTableView.cellFont]).width
        #expect(column.width >= needed)
    }

    // MARK: - Helpers

    /// A table showing `text` in a laid-out surface, and what removes its window.
    private static func table(_ text: String) async throws -> (QuickViewTableView, () -> Void) {
        let tree = try TempDirectory()
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("data.csv", contents: text)
        )
        let surface = try #require(preview.tableSurface)
        return (surface, { tree.cleanup() })
    }

    /// Click the header of the table's column `column` (0 is `#`), and wait for the sort to land.
    private static func click(_ surface: QuickViewTableView, column: Int) async throws {
        let tableColumn = surface.tableView.tableColumns[column]
        let prototype = try #require(tableColumn.sortDescriptorPrototype)
        let current = surface.tableView.sortDescriptors.first
        let descriptor = current?.key == prototype.key ? try #require(
            current?.reversedSortDescriptor as? NSSortDescriptor
        ) : prototype
        let before = surface.sortGeneration
        let previousTask = surface.sortTask
        surface.tableView.sortDescriptors = [descriptor]
        #expect(surface.sortGeneration > before)
        // A column sort lands when its task does; the `#` column's order is applied at once.
        if let task = surface.sortTask, task != previousTask {
            await task.value
        }
    }

    /// The text column `column` draws, top to bottom.
    private static func column(_ surface: QuickViewTableView, _ column: Int) -> [String] {
        (0..<surface.tableView.numberOfRows).compactMap {
            QuickViewTableFixtures.cellText(surface, row: $0, column: column)
        }
    }
}
