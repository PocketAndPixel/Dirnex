import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Regular Expression, the third option in the bar's magnifying glass (2026-09-18).
///
/// What a pattern *means* is `DirnexCore`'s and is tested there (`PatternSearchTests`), down to the
/// range macOS's own engine gets wrong. What these pin is the half only the app has: that the option
/// reaches a surface that finds and one that narrows, and that a pattern half typed — which is most
/// of them, most of the time — says so where the count goes instead of reporting nothing at all.
@Suite("Quick View pattern search")
@MainActor
struct QuickViewPatternFindTests {
    private typealias Text = QuickViewTextFindFixtures
    private typealias Typing = QuickViewTableFilterFixtures

    private static let sample = "alpha beta\nbeta42 gamma\nbetaOnly\nbeer\n"

    @Test("the text typed is read as a pattern, and each surface counts the same matches")
    func findingAndNarrowing() async throws {
        let text = try await Text.text(Self.sample)
        defer { text.cleanup() }
        try await Typing.type("be(ta|er)", into: text.surface)
        #expect(
            text.surface.find.matches?.isEmpty == true,
            "literally, nothing in the file spells that"
        )

        text.surface.filterBar.applyOptions(.pattern)
        await text.surface.filterTask?.value
        #expect(text.surface.find.matches?.count == 4, "three betas and the beer")
        #expect(text.surface.filterBar.countLabel.stringValue.contains("4"))

        let table = try await Typing.table("name,size\nalpha.txt,10\nbeta.log,20\ngamma.txt,30\n")
        defer { table.cleanup() }
        table.surface.filterBar.applyOptions(.pattern)
        try await Typing.type("\\.txt$", into: table.surface)
        #expect(table.surface.tableView.numberOfRows == 2)
        try await Typing.type("^b", into: table.surface)
        #expect(table.surface.tableView.numberOfRows == 1, "an anchor is the cell's own start")
    }

    @Test("a pattern half typed says so where the count goes")
    func invalidPatternIsSaid() async throws {
        let fixture = try await Text.text(Self.sample)
        defer { fixture.cleanup() }
        let bar = fixture.surface.filterBar
        bar.applyOptions(.pattern)
        try await Typing.type("be(ta", into: fixture.surface)
        #expect(fixture.surface.find.matches?.isEmpty == true)
        #expect(bar.patternProblem != nil)
        #expect(bar.countLabel.stringValue == bar.patternProblem)

        // Finished, it is a count again — the sentence is a state, not something left on screen.
        try await Typing.type("be(ta)", into: fixture.surface)
        #expect(bar.patternProblem == nil)
        #expect(bar.countLabel.stringValue.contains("3"))
    }

    /// A back reference is a pattern every other tool would take, refused here for a measured reason,
    /// so it says that rather than calling the user's pattern invalid.
    @Test("a back reference gets its own sentence")
    func backReferenceIsSaid() async throws {
        let fixture = try await Text.text(Self.sample)
        defer { fixture.cleanup() }
        let bar = fixture.surface.filterBar
        bar.applyOptions(.pattern)
        try await Typing.type("(bet)\\1", into: fixture.surface)
        let refusal = try #require(bar.patternProblem)
        #expect(bar.countLabel.stringValue == refusal)

        try await Typing.type("(bet", into: fixture.surface)
        #expect(
            bar.patternProblem != refusal,
            "not the same sentence as a pattern that will not parse"
        )
    }

    /// The sentence belongs to the option, not to the surface: a table that narrows says it where its
    /// row count goes, and the rows it is left with are none.
    @Test("a table says it too, where its row count goes")
    func invalidPatternOverATable() async throws {
        let fixture = try await Typing.table(Typing.sample)
        defer { fixture.cleanup() }
        let bar = fixture.surface.filterBar
        bar.applyOptions(.pattern)
        try await Typing.type("cv/[", into: fixture.surface)
        #expect(bar.patternProblem != nil)
        #expect(bar.countLabel.stringValue == bar.patternProblem)
        #expect(fixture.surface.tableView.numberOfRows == 0)

        try await Typing.type("cv/[cu]", into: fixture.surface)
        #expect(bar.patternProblem == nil)
        #expect(fixture.surface.tableView.numberOfRows == 2)
    }

    /// The rows are chosen by one query and marked by another, built at a different call site — so
    /// the marks are their own piece of plumbing, and a pattern that narrowed correctly can still be
    /// marked as though it were text to find literally.
    @Test("what the pattern matched is marked in the cell")
    func marksFollowThePattern() async throws {
        let fixture = try await Typing.table("label,code\ncv/create,200\ncv/update,500\n")
        defer { fixture.cleanup() }
        fixture.surface.filterBar.applyOptions(.pattern)
        try await Typing.type("[0-9]+", into: fixture.surface)
        #expect(fixture.surface.tableView.numberOfRows == 2)
        #expect(
            QuickViewFilterMarksTests.marks(fixture.surface.tableView, row: 0, column: 2) == ["200"]
        )
        #expect(
            QuickViewFilterMarksTests.marks(fixture.surface.tableView, row: 0, column: 1).isEmpty
        )
    }

    /// Nothing typed is not an invalid pattern: the bar goes quiet, as it does without the option.
    @Test("an empty bar says nothing whatever the options are")
    func emptyBarSaysNothing() async throws {
        let fixture = try await Text.text(Self.sample)
        defer { fixture.cleanup() }
        let bar = fixture.surface.filterBar
        bar.applyOptions(.pattern)
        try await Typing.type("", into: fixture.surface)
        #expect(bar.patternProblem == nil)
        #expect(bar.countLabel.stringValue.isEmpty)
    }

    /// The option is a mode like the other two: it survives a new file, and it is stored by name.
    @Test("the option outlives the file and the process")
    func optionIsRemembered() async throws {
        let defaults = ScratchDefaults.fresh()
        QuickViewFindOptionsStore(defaults: defaults).apply(.pattern)
        #expect(QuickViewFindOptionsStore(defaults: defaults).options == .pattern)
        #expect(defaults.stringArray(forKey: "Dirnex.quickView.findOptions") == ["pattern"])
    }
}
