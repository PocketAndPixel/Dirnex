import Foundation

/// Merging standard places into the pin list — the ordering half of PLAN.md §M8 "the hotlist
/// *becomes* the sidebar's Favorites section".
///
/// The once-only trigger and the `UserDefaults` flag behind it are app policy (`HotlistStore`
/// owns those, as it owns the rest of the persistence); what lives here is the rule for how a
/// seeded list and a user's existing pins interleave, so it stays unit-testable headless like
/// the rest of `Hotlist`.
public extension HotlistEntry {
    /// Pin a standard place under its *place* name rather than its folder name.
    ///
    /// Not cosmetic, and the reason this exists instead of the conversion being inlined at the
    /// call site: `HotlistEntry(path:)` derives the label from the path's last component, which
    /// for `/Users/oleg` is the account name. Seeding through the generic initializer would put a
    /// row called "oleg" at the top of every sidebar.
    init(place: FavoritePlace) {
        self.init(name: place.name, path: place.path)
    }
}

public extension Hotlist {
    /// Insert `newEntries` at the front, ahead of everything already pinned.
    ///
    /// A path present in both lands **at the prepended position, under the prepended name** —
    /// the user's existing entry is dropped rather than moved down. That collision rule is the
    /// entire point at the seeding call site: someone who pinned `~/Downloads` as "Dl" gets the
    /// standard "Downloads" row in Finder's position, not their old label stranded above the
    /// seeded block. It costs them a custom name, which is the accepted trade for a sidebar that
    /// looks unchanged on the launch after the merge (PLAN.md §7, resolved 2026-07-20).
    ///
    /// The de-duplication itself is not reimplemented here: `init(entries:)` already collapses
    /// duplicate paths keeping the *first* occurrence, so prepending and re-initializing gives
    /// exactly this semantic from the one rule that already exists.
    ///
    /// Returns whether the list actually changed, so a caller can skip a needless write.
    @discardableResult
    mutating func prepend(_ newEntries: [HotlistEntry]) -> Bool {
        let before = entries
        self = Hotlist(entries: newEntries + before)
        return entries != before
    }
}
