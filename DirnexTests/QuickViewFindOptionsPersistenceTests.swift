import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Case Sensitive and Whole Word remembered across Quick View's five surfaces and across launches
/// (2026-09-18) — the half `QuickViewFindOptionsTests` deliberately left out when the options lived
/// on each bar. Two claims: a choice made over one surface is already made over the next, and it is
/// still made by a store built afterwards, which is what a relaunch is.
@Suite("Quick View find options persistence")
@MainActor
struct QuickViewFindOptionsPersistenceTests {
    private typealias Fixtures = QuickViewTableFilterFixtures

    /// The key, as a literal rather than through the store: it is API from the moment a build ships
    /// that writes it, so a test that read it back off the type under test could not see it move.
    private static let key = "Dirnex.quickView.findOptions"

    private static let text = "alpha Beta\nbeta gamma\nBETA delta\n"

    @Test("a choice outlives the store that made it, which is what a relaunch is")
    func optionsSurviveTheProcess() {
        let defaults = ScratchDefaults.fresh()
        QuickViewFindOptionsStore(defaults: defaults).apply([.caseSensitive, .wholeWord])
        #expect(
            QuickViewFindOptionsStore(defaults: defaults).options == [.caseSensitive, .wholeWord]
        )
        #expect(
            defaults.stringArray(forKey: Self.key) == ["caseSensitive", "wholeWord"],
            "stored by name, so the option set's raw bits never become a compatibility surface"
        )
    }

    @Test("turning them all off leaves no key behind, and reads back as off")
    func clearingRemovesTheKey() {
        let defaults = ScratchDefaults.fresh()
        let store = QuickViewFindOptionsStore(defaults: defaults)
        store.apply(.caseSensitive)
        store.apply([])
        #expect(defaults.object(forKey: Self.key) == nil)
        #expect(QuickViewFindOptionsStore(defaults: defaults).options.isEmpty)
    }

    /// The tolerant read. A newer build's name is dropped and the rest still read; a value that is
    /// not an array of strings at all falls back to the default rather than trapping or half-applying.
    @Test("a value from somewhere else degrades rather than trapping")
    func aForeignValueDegrades() {
        let defaults = ScratchDefaults.fresh()
        defaults.set(["caseSensitive", "regexFromANewerBuild"], forKey: Self.key)
        #expect(QuickViewFindOptionsStore(defaults: defaults).options == .caseSensitive)

        for garbage in [42, "caseSensitive", [1, 2], ["wholeWord", 7]] as [Any] {
            defaults.set(garbage, forKey: Self.key)
            #expect(
                QuickViewFindOptionsStore(defaults: defaults).options.isEmpty,
                "\(garbage) should read as the default"
            )
        }
    }

    /// The plumbing control — the one a five-surface change can silently miss. Each surface builds its
    /// own bar, so a preview that handed one of them a store of its own would share the options with
    /// every surface but that one, and only over that kind of file.
    @Test("every surface's bar is on the preview's own store")
    func everySurfaceSharesTheStore() async throws {
        let fixture = try await Fixtures.table(Fixtures.sample)
        defer { fixture.cleanup() }
        let preview = fixture.preview
        let store = preview.findOptions
        #expect(preview.tableSurface?.filterBar.findOptions === store)

        // A second kind of file into the same preview, so two surfaces are alive at once.
        let notes = try fixture.tree.write("notes.txt", contents: Self.text)
        preview.show(notes, style: .rendered)
        for _ in 0..<400 where preview.textSurface == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(preview.textSurface?.filterBar.findOptions === store)
    }

    @Test("an option turned on over one surface is already on over the next")
    func anOptionCarriesToAnotherSurface() async throws {
        let fixture = try await Fixtures.table(Fixtures.sample)
        defer { fixture.cleanup() }
        let preview = fixture.preview
        let notes = try fixture.tree.write("notes.txt", contents: Self.text)
        preview.show(notes, style: .rendered)
        for _ in 0..<400 where preview.textSurface == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let table = try #require(preview.tableSurface)
        let text = try #require(preview.textSurface)

        text.filterBar.applyOptions(.caseSensitive)

        #expect(table.filterBar.options == .caseSensitive)
        let items = try #require(table.filterBar.field.searchMenuTemplate).items
        let checked = items.filter { $0.state == .on }.map(\.tag)
        #expect(
            checked == [FilterQuery.Options.caseSensitive.rawValue],
            "the other bar's menu is rebuilt too, not just its value"
        )
    }

    /// The behavioural half of the one above: the other surface does not merely *know* the option, it
    /// searches again under it. Without that a table left filtered would go on showing rows the new
    /// reading excludes, which is the stale-count bug the options' own tests pin one surface at a time.
    @Test("the other surface searches again under the new options")
    func theOtherSurfaceSearchesAgain() async throws {
        // The text file first, so the table is the surface *showing* when the option is turned on:
        // showing a new file clears the bar, so a table filtered before the second file would have
        // nothing left to re-filter and the test would pass on an empty table either way.
        let fixture = try await QuickViewTextFindFixtures.text(Self.text)
        defer { fixture.cleanup() }
        let preview = fixture.preview
        let text = fixture.surface

        let csv = try fixture.tree.write("data.csv", contents: "label\nbeta\nBeta\nBETA\n")
        preview.show(csv, style: .rendered)
        for _ in 0..<400 where preview.tableSurface?.table == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let table = try #require(preview.tableSurface)
        try await Fixtures.type("beta", into: table)
        #expect(table.rows.count == 3, "case folds by default")

        text.filterBar.applyOptions(.caseSensitive)
        await table.filterTask?.value
        #expect(
            table.rows.count == 1,
            "`beta` alone, the table having re-filtered on the notification"
        )
    }

    /// Scoping. Every bar in the app observes one notification name, so a store that did not filter
    /// by `object:` would have a test's bar — and the developer's real Quick View — searching again
    /// on somebody else's change.
    ///
    /// The observable is the *re-search*, not the options: a bar reads its own store, so an unscoped
    /// observer still reports the right value and the obvious assertion passes in both directions
    /// (measured — it did). What an unscoped bar does differently is run `changed()` for a change that
    /// was never its own.
    @Test("a bar hears its own store and no other")
    func storesDoNotCrossTalk() async throws {
        final class Box { var calls = 0 }
        let fixture = try await Fixtures.table(Fixtures.sample)
        defer { fixture.cleanup() }
        let table = try #require(fixture.preview.tableSurface)
        let stranger = QuickViewFindOptionsStore(defaults: ScratchDefaults.fresh("stranger"))
        let box = Box()
        let surfacesOwn = table.filterBar.changed
        table.filterBar.changed = { box.calls += 1; surfacesOwn() }

        stranger.apply([.caseSensitive, .wholeWord])
        #expect(box.calls == 0, "another store's change is not this bar's")
        #expect(table.filterBar.options.isEmpty)

        // The narrowness half, or "hears nothing" would pass this test just as well.
        fixture.preview.findOptions.apply(.caseSensitive)
        #expect(box.calls == 1)
        #expect(table.filterBar.options == .caseSensitive)
    }

    /// The menu's completeness guard, the app-side twin of `FilterQueryOptionNamesTests`. An option
    /// added to the core without a title here would be storable and unofferable — there would be no
    /// way to turn it on.
    @Test("the menu offers every option the core has")
    func theMenuOffersEveryOption() {
        let offered = QuickViewTableFilterBar.optionTitles.reduce(into: FilterQuery.Options()) {
            $0.insert($1.0)
        }
        #expect(offered == FilterQuery.Options.all)
        #expect(QuickViewTableFilterBar.optionTitles.count == FilterQuery.Options.named.count)
    }
}
