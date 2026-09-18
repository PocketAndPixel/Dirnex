import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Case Sensitive and Whole Word in the bar (2026-09-18). What the options *mean* is `DirnexCore`'s
/// and is tested there (`FilterQueryOptionsTests`); what these pin is the bar and the surfaces — that
/// the menu offers both and reflects what is on, that turning one on re-runs the search rather than
/// leaving a stale count on screen, that the options outlive a new file, and that the same two reach a
/// surface that *narrows* as well as one that *finds*.
@Suite("Quick View find options")
@MainActor
struct QuickViewFindOptionsTests {
    private typealias Fixtures = QuickViewTextFindFixtures
    private typealias Typing = QuickViewTableFilterFixtures

    private static let sample = "alpha Beta\nbeta gamma\nBETA delta\nbetaOnly\n"

    private func menu(of bar: QuickViewTableFilterBar) throws -> NSMenu {
        try #require(bar.field.searchMenuTemplate)
    }

    @Test("the magnifying glass offers every option, unchecked to begin with")
    func menuOffersEveryOption() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let items = try menu(of: fixture.surface.filterBar).items
        #expect(items.allSatisfy { $0.state == .off })
        #expect(items.allSatisfy { !$0.title.isEmpty })
        // By tag, not by title: the titles are translated and the app test target inherits whichever
        // `AppleLanguages` Dirnex is pinned to (docs/NOTES.md ▸ Localization). And against the option
        // set rather than a count, which would expire the day a fourth one is added.
        let offered = items.reduce(into: FilterQuery.Options()) {
            $0.insert(FilterQuery.Options(rawValue: $1.tag))
        }
        #expect(offered == FilterQuery.Options.all)
        #expect(items.count == FilterQuery.Options.named.count)
        #expect(fixture.surface.filterBar.options.isEmpty)
    }

    @Test("turning Case Sensitive on re-runs the search and narrows the matches")
    func caseSensitiveRerunsTheSearch() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(surface.find.matches?.count == 4)

        surface.filterBar.applyOptions(.caseSensitive)
        await surface.filterTask?.value
        #expect(surface.find.matches?.count == 2, "`beta` and `betaOnly`, not `Beta` or `BETA`")
        #expect(surface.filterBar.countLabel.stringValue.contains("2"))
    }

    @Test("turning Whole Word on drops a match inside a longer word")
    func wholeWordRerunsTheSearch() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(surface.find.matches?.count == 4)

        surface.filterBar.applyOptions(.wholeWord)
        await surface.filterTask?.value
        #expect(surface.find.matches?.count == 3, "`betaOnly` is no longer one")
    }

    @Test("both together")
    func bothTogether() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        surface.filterBar.applyOptions([.caseSensitive, .wholeWord])
        await surface.filterTask?.value
        #expect(surface.find.matches?.count == 1)
    }

    @Test("the menu shows which options are on")
    func menuReflectsTheState() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let bar = fixture.surface.filterBar
        bar.applyOptions(.wholeWord)
        let items = try menu(of: bar).items
        let states = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0.state) })
        #expect(states[FilterQuery.Options.wholeWord.rawValue] == .on)
        #expect(states[FilterQuery.Options.caseSensitive.rawValue] == .off)
    }

    /// The menu is rebuilt from the stored value rather than by toggling the item that was clicked,
    /// because `NSSearchField` copies its template to display it. Driving the action with a *detached*
    /// item — which is what a copy is, as far as the bar is concerned — has to work.
    @Test("a click arriving on a copy of the menu item still toggles")
    func toggleFromADetachedItem() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let bar = fixture.surface.filterBar
        let original = try #require(try menu(of: bar).items.first)
        let copy = try #require(original.copy() as? NSMenuItem)
        #expect(copy !== original)
        _ = bar.perform(copy.action, with: copy)
        #expect(bar.options.contains(FilterQuery.Options(rawValue: copy.tag)))
        // And the template held by the bar is the one that now shows the checkmark.
        let refreshed = try #require(try menu(of: bar).items.first { $0.tag == copy.tag })
        #expect(refreshed.state == .on)
    }

    /// An option is a mode, not content: a new file clears the text and the matches and keeps the way
    /// the next text will be read, so walking a folder with Case Sensitive on does not turn it off at
    /// every arrow key.
    @Test("a new file keeps the options and forgets the search")
    func optionsOutliveTheFile() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        surface.filterBar.applyOptions(.caseSensitive)
        try await Typing.type("beta", into: surface)
        #expect(surface.find.matches?.count == 2)

        surface.resetFind()
        #expect(surface.find.matches == nil, "the search is gone")
        #expect(surface.filterBar.query.isEmpty)
        #expect(surface.filterBar.options == .caseSensitive, "and the mode is not")
    }

    /// The same two options on a surface that narrows rather than finds — the consistency the whole
    /// design rests on, since one bar must not mean two things.
    @Test("the options reach a table's filter as well")
    func tableTakesTheOptions() async throws {
        let fixture = try await Typing.table("name,note\nBeta,one\nbeta,two\nbetaOnly,three\n")
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        let all = surface.rows.count

        surface.filterBar.applyOptions(.caseSensitive)
        await surface.filterTask?.value
        let sensitive = surface.rows.count
        #expect(sensitive < all, "`Beta` no longer matches")

        surface.filterBar.applyOptions([])
        await surface.filterTask?.value
        #expect(surface.rows.count == all, "and clearing the option gives the rows back")
    }
}
