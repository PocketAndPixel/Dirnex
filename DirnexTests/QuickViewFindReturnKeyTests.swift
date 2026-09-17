import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What Return does in the find bar, and what the menu item calls it (2026-09-18).
///
/// Return used to hand the keyboard back on every surface. On one that *finds* it now steps to the
/// next match and ⇧Return to the previous one, which is what every other find bar on the Mac does;
/// on one that *narrows* it still hands the keyboard back, because there the rows are the result and
/// ↑ and ↓ are already walking them (`QuickViewTableFilterKeysTests` pins that half).
///
/// The direction is a *parameter* of `filterCommand`, not a read of `NSEvent.modifierFlags` inside
/// it — measured 2026-09-18, a field editor turns Return and ⇧Return into the same `insertNewline:`
/// and never sends `insertLineBreak:`, so the selector cannot carry it and a rule reading the live
/// keyboard would have exactly one reachable test case (docs/NOTES.md ▸ Testing).
@Suite("Quick View find Return key")
@MainActor
struct QuickViewFindReturnKeyTests {
    private typealias Fixtures = QuickViewTextFindFixtures
    private typealias Typing = QuickViewTableFilterFixtures

    private static let sample = "alpha Beta\nbeta gamma\nBETA delta\n"
    private static let newline = #selector(NSResponder.insertNewline(_:))

    @Test("Return steps to the next match and keeps the keyboard in the bar")
    func returnStepsForward() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        var returned = 0
        surface.returnKeyboard = { returned += 1 }
        try await Typing.type("beta", into: surface)
        #expect(surface.find.current == 0)

        #expect(surface.filterCommand(Self.newline, modifiers: []))
        #expect(surface.find.current == 1)
        #expect(surface.filterCommand(Self.newline, modifiers: []))
        #expect(surface.find.current == 2)
        // Past the last match it wraps, exactly as ↓ does — one stepping rule, two keys.
        #expect(surface.filterCommand(Self.newline, modifiers: []))
        #expect(surface.find.current == 0)
        #expect(returned == 0, "the keyboard stays in the bar so Return can be pressed again")
        #expect(surface.filterHasKeyboard)
    }

    @Test("⇧Return steps to the previous match")
    func shiftReturnStepsBackward() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        var returned = 0
        surface.returnKeyboard = { returned += 1 }
        try await Typing.type("beta", into: surface)

        // Backwards from the first match wraps to the last.
        #expect(surface.filterCommand(Self.newline, modifiers: .shift))
        #expect(surface.find.current == 2)
        #expect(surface.filterCommand(Self.newline, modifiers: .shift))
        #expect(surface.find.current == 1)
        #expect(returned == 0)
    }

    /// The half that keeps the key from ever being dead: with nothing typed, or nothing found, there
    /// is no match to step to and Return falls through to what it always did.
    @Test("Return with nothing to step to hands the keyboard back")
    func returnWithoutMatchesHandsTheKeyboardBack() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        var returned = 0
        surface.returnKeyboard = { returned += 1 }

        surface.beginFiltering()
        #expect(!surface.returnStepsResults, "nothing is typed")
        #expect(surface.filterCommand(Self.newline, modifiers: []))
        #expect(returned == 1)

        try await Typing.type("nowhere-in-this-text", into: surface)
        #expect(surface.find.matches?.isEmpty == true)
        #expect(!surface.returnStepsResults, "the text is found nowhere")
        #expect(surface.filterCommand(Self.newline, modifiers: []))
        #expect(returned == 2)
    }

    /// Tab is untouched, and is what still leaves the field on a surface where Return no longer does.
    @Test("Tab still hands the keyboard back while finding")
    func tabStillLeaves() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        var returned = 0
        surface.returnKeyboard = { returned += 1 }
        try await Typing.type("beta", into: surface)
        #expect(surface.filterCommand(#selector(NSResponder.insertTab(_:)), modifiers: []))
        #expect(returned == 1)
        #expect(surface.find.current == 0, "and it steps nothing on the way out")
    }

    /// The narrowness half, asserted on the surface the other suite covers behaviourally: the fork is
    /// keyed on the *kind* of host, so a row filter must answer `false` however many rows it found.
    @Test("a surface that narrows does not step on Return")
    func rowFilterDoesNotStep() async throws {
        let fixture = try await QuickViewTableFilterFixtures.table(
            QuickViewTableFilterFixtures.sample
        )
        defer { fixture.cleanup() }
        #expect(!fixture.surface.returnStepsResults)
        try await QuickViewTableFilterFixtures.type("delta", into: fixture.surface)
        #expect(!fixture.surface.returnStepsResults, "still false with rows matched")
    }

    /// The menu item names which of the two things ⌥⌘F would do. Asserted against the catalog rather
    /// than against English, since the app test target inherits whichever `AppleLanguages` Dirnex is
    /// pinned to (docs/NOTES.md ▸ Localization).
    @Test("the menu item is titled for finding or for filtering, never both")
    func menuItemTitle() async throws {
        let filtering = try #require(BrowserWindowController.filterItemTitle(finding: false))
        let finding = try #require(BrowserWindowController.filterItemTitle(finding: true))
        #expect(!filtering.isEmpty)
        #expect(!finding.isEmpty)
        #expect(filtering != finding, "the two states must not read the same")
        #expect(
            filtering == LocalizedCatalog.command(for: "view.quickViewFilterTable")?.title,
            "the filter title is the registry's own, not a second literal saying the same thing"
        )
    }

    /// And the input that chooses between them: a text preview is a find host and a table is not, so
    /// the title follows what is on screen.
    @Test("a text preview is a find host and a table is not")
    func surfaceKindDecidesTheTitle() async throws {
        let table = try await QuickViewTableFilterFixtures.table(QuickViewTableFilterFixtures.sample)
        defer { table.cleanup() }
        #expect(!(table.preview.filterableSurface is (any QuickViewFindHost)))

        let text = try await QuickViewTableFixtures.loaded(
            try table.tree.write("notes.txt", contents: "plain text\n")
        )
        #expect(text.filterableSurface is (any QuickViewFindHost))
    }
}
