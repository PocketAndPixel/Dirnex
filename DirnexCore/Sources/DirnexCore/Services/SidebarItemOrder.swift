import Foundation

/// A user-chosen order over rows the app **discovers** rather than stores — today the sidebar's
/// Cloud section, whose rows are iCloud Drive plus whatever is mounted under
/// `~/Library/CloudStorage` (PLAN.md §M8, §M10).
///
/// Favorites, Searches and Servers each reorder by rewriting the list that *is* the section: the
/// entries are the user's own, so their order is simply the array's. A discovered section has no
/// such list — its rows come back from a scan every rebuild, in whatever order the scan produces —
/// so the user's order has to be stored *beside* them, as identities. That is the whole of this
/// type: an ordered list of opaque identity strings, and the two operations a discovered section
/// needs — sort a freshly scanned set by it, and rewrite it after a drag.
///
/// The identities are the caller's to choose and are never interpreted here, which is what keeps a
/// presentation decision out of the core (docs/NOTES.md: "a presentation decision in the core is a
/// string that can never be translated" — the same rule, one level up). They only have to be
/// **stable across launches**: the Cloud section keys a mount off its directory name under
/// `~/Library/CloudStorage`, which is the one thing about a mount that does not change when a
/// second account of the same provider appears and re-labels the row.
public struct SidebarItemOrder: Equatable, Sendable, Codable {
    /// The identities in user order, including any whose item is not on screen right now.
    public private(set) var identities: [String]

    public init(identities: [String] = []) {
        // Collapse duplicates on the way in (a hand-edited store), keeping the first occurrence, so
        // an identity maps to a single position — the same sanitizing `Favorites.init` does.
        var seen = Set<String>()
        self.identities = identities.filter { seen.insert($0).inserted }
    }

    /// Sort `items` into the stored order: the ones this order knows about first, in it, then
    /// everything else in the order the scan produced.
    ///
    /// Unknown items go to the **end**, deliberately. A mount that appears after the user has
    /// arranged the section is new, and new things land at the bottom of a hand-arranged list —
    /// filing it into its alphabetical slot would move a row the user placed by hand. An order that
    /// knows nothing (a fresh install) therefore leaves the scan's own order completely untouched.
    public func apply<Item>(to items: [Item], id: (Item) -> String) -> [Item] {
        var byIdentity: [String: [Item]] = [:]
        var unknown: [Item] = []
        let known = Set(identities)
        for item in items {
            let identity = id(item)
            if known.contains(identity) {
                byIdentity[identity, default: []].append(item)
            } else {
                unknown.append(item)
            }
        }
        return identities.flatMap { byIdentity[$0] ?? [] } + unknown
    }

    /// Rewrite the order after a drag: `displayed` is the section's identities as they are on
    /// screen, and the item at `source` moves so it lands at `destination` in the *resulting* list
    /// (Array semantics, matching `Favorites.move`). The app adjusts a raw `NSTableView` drop row
    /// into that convention before calling.
    public mutating func reorder(displayed: [String], from source: Int, to destination: Int) {
        guard displayed.indices.contains(source) else { return }
        var moved = displayed
        let identity = moved.remove(at: source)
        moved.insert(identity, at: min(max(destination, 0), moved.count))
        record(moved)
    }

    /// Fold a section's on-screen order into the stored one, **keeping absent items where they
    /// were**.
    ///
    /// The obvious version — store `displayed` and drop the rest — loses the position of anything
    /// not currently mounted, so signing out of one Drive account and dragging another row would
    /// silently send the first to the bottom of the section on the day it comes back. Instead the
    /// stored list keeps its shape: every slot held by an item that *is* on screen is refilled from
    /// the new order in sequence, each absent identity keeps its own slot, and identities the order
    /// had never seen are appended.
    private mutating func record(_ displayed: [String]) {
        let onScreen = Set(displayed)
        var incoming = displayed[...]
        var result: [String] = []
        for identity in identities {
            if onScreen.contains(identity) {
                if let next = incoming.popFirst() { result.append(next) }
            } else {
                result.append(identity)
            }
        }
        result.append(contentsOf: incoming)
        identities = result
    }

    // MARK: - Codable

    // A bare array of names, like `SidebarSectionCollapse`: it is one list, and the file is meant to
    // be readable (PLAN.md §2 "boring and debuggable").
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Through the de-duplicating initializer, so a hand-edited store is sanitized on the way in.
        self.init(identities: try container.decode([String].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identities)
    }
}
