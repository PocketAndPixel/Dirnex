import AppKit
import Foundation
import Testing

@testable import Dirnex

/// Row density (PLAN.md §M15 Slice 1). Presentation, so it is tested here rather than in
/// `DirnexCore`, the way `SyncBadgeTests` already is.
///
/// Three claims, and the third is the one that exists because of a measurement. A probe against a
/// real 300-row `NSTableView` found that `reloadData` empties the reuse pool outright — so a
/// density change happens to hand out freshly built cells today, and the stale-icon bug this guards
/// cannot currently be reproduced through the table. That is exactly why it is pinned at the
/// *cell*: the behaviour is undocumented, and if a macOS ever kept the pool the failure would be
/// silent — 16 pt icons in a 28 pt row, nothing logged.
@Suite("Row density")
@MainActor
struct RowDensityTests {
    /// The floor every row has to clear, measured rather than assumed: an `NSTextField` label at
    /// the system font reports an intrinsic height of exactly 16.00 pt, bold included — and bold is
    /// what a *marked* row draws, so it is the binding case.
    @Test("every density leaves room for the text, which is what actually sets the floor")
    func rowsClearTheTextFloor() {
        let label = NSTextField(labelWithString: "Ag—Йф")
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let floor = label.intrinsicContentSize.height
        #expect(floor == 16)

        for density in RowDensity.allCases {
            #expect(density.rowHeight >= floor)
            // The icon shares the row with nothing above or below it, so it must fit too.
            #expect(density.iconSize <= density.rowHeight)
        }
    }

    /// `.regular` is not "the middle one", it is *today's* pane. An untouched install must render
    /// byte-identically to the build before this setting existed, which those two numbers are.
    @Test("regular is the 22/16 the pane was hardcoded to, and the steps are strictly ordered")
    func regularReproducesTheShippedGeometry() {
        #expect(RowDensity.regular.rowHeight == 22)
        #expect(RowDensity.regular.iconSize == 16)

        let ordered: [RowDensity] = [.compact, .regular, .roomy]
        #expect(ordered == RowDensity.allCases)
        #expect(zip(ordered, ordered.dropFirst()).allSatisfy { $0.rowHeight < $1.rowHeight })
        #expect(zip(ordered, ordered.dropFirst()).allSatisfy { $0.iconSize < $1.iconSize })
    }

    /// The recycled-cell case: a cell built at one density and handed back at another must re-lay
    /// its icon, not keep the box it was born with.
    @Test("a cell re-densified in place resizes its icon — the recycled-cell case")
    func recycledCellFollowsTheDensity() throws {
        let cell = FileCellView(
            showsImage: true,
            identifier: NSUserInterfaceItemIdentifier("name")
        )
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: RowDensity.regular.rowHeight)
        cell.layoutSubtreeIfNeeded()
        let image = try #require(cell.imageView)
        #expect(image.frame.height == RowDensity.regular.iconSize)

        // What `tableView(_:viewFor:row:)` does to a cell that came out of the reuse pool.
        cell.density = .roomy
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: RowDensity.roomy.rowHeight)
        cell.layoutSubtreeIfNeeded()
        #expect(image.frame.height == RowDensity.roomy.iconSize)
        #expect(image.frame.width == RowDensity.roomy.iconSize)

        // And back down — the constraint is re-derived from the density, never accumulated.
        cell.density = .compact
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: RowDensity.compact.rowHeight)
        cell.layoutSubtreeIfNeeded()
        #expect(image.frame.height == RowDensity.compact.iconSize)
    }

    /// A cell with no image (Size, Date, the Git gutter) has no icon constraints to move; setting a
    /// density on it must be inert rather than a trap.
    @Test("a text-only cell takes a density without complaint")
    func textOnlyCellIgnoresDensity() {
        let cell = FileCellView(
            showsImage: false,
            identifier: NSUserInterfaceItemIdentifier("size")
        )
        cell.density = .roomy
        #expect(cell.imageView == nil)
    }

    @Test("the preference defaults to regular and round-trips through UserDefaults")
    func preferenceRoundTrips() throws {
        let suiteName = "RowDensityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A fresh install is the shipped 22 pt row.
        #expect(AppPreferences(defaults: defaults).rowDensity == .regular)

        let preferences = AppPreferences(defaults: defaults)
        preferences.rowDensity = .compact
        #expect(AppPreferences(defaults: defaults).rowDensity == .compact)

        // A value this build has never heard of falls back rather than trapping.
        defaults.set("enormous", forKey: "Dirnex.pref.rowDensity")
        #expect(AppPreferences(defaults: defaults).rowDensity == .regular)
    }

    @Test("changing the density posts the notification open panes re-render on")
    func changePostsNotification() throws {
        let suiteName = "RowDensityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppPreferences.rowDensityDidChange,
            object: preferences,
            queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.rowDensity = .roomy
        #expect(posts == 1)
        // Re-assigning the same value must not churn every open pane.
        preferences.rowDensity = .roomy
        #expect(posts == 1)
    }
}
