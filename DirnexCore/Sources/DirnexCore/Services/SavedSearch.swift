import Foundation

/// A named, re-runnable Spotlight search — the model behind the sidebar's **Searches** section
/// (PLAN.md §M4 "Saved searches as virtual folders in the places strip"). It pairs the tested
/// `SpotlightQuery` with a display name and the folder scope it runs against, so picking it from
/// the places strip re-runs the query and lands the hits in a fresh virtual results panel — the
/// macOS answer to Finder's Smart Folders.
///
/// Identity is the name, so a search is saved once per name (re-saving under an existing name
/// updates it in place), matching `Workspace`.
public struct SavedSearch: Sendable, Equatable, Identifiable, Codable {
    /// The user-facing label shown in the sidebar and the save prompt — and the search's
    /// identity: at most one saved search per name.
    public var name: String
    /// What to look for. The pure, tested query the app renders into `mdfind` arguments.
    public var query: SpotlightQuery
    /// The folder whose subtree the search is limited to, or `nil` to search everywhere indexed
    /// (mirrors the Find sheet's "This Folder" vs "Everywhere"). A scoped search re-runs against
    /// this absolute path regardless of where the active pane currently is.
    public var scope: VFSPath?

    public init(name: String, query: SpotlightQuery, scope: VFSPath? = nil) {
        self.name = name
        self.query = query
        self.scope = scope
    }

    public var id: String { name }
}

/// An ordered, name-de-duplicated collection of saved searches — the model behind the sidebar's
/// Searches section and its right-click management. A pure value type with no persistence or
/// AppKit: the app owns the `UserDefaults` store and the sidebar UI, this owns the ordering and
/// naming rules so they stay unit-testable headless (matching `Workspaces` and `Favorites`).
public struct SavedSearches: Sendable, Equatable, Codable {
    /// The saved searches in user order — the order the sidebar presents.
    public private(set) var searches: [SavedSearch]

    public init(searches: [SavedSearch] = []) {
        // Collapse duplicate names on the way in (a hand-edited or legacy store), keeping the
        // first occurrence so a name maps to a single search.
        var seen = Set<String>()
        self.searches = searches.filter { seen.insert($0.name).inserted }
    }

    /// Whether a search named `name` exists — drives the Save prompt's replace confirmation.
    public func contains(name: String) -> Bool {
        searches.contains { $0.name == name }
    }

    /// The search named `name`, or `nil` — the sidebar looks one up by name so a mid-open store
    /// change can't run the wrong (index-shifted) search.
    public func search(named name: String) -> SavedSearch? {
        searches.first { $0.name == name }
    }

    /// Save `search`: overwrite an existing one with the same name *in place* (keeping its
    /// position), else append. Returns whether it replaced an existing search — the app only
    /// asks the user to confirm a replacement.
    @discardableResult
    public mutating func save(_ search: SavedSearch) -> Bool {
        if let index = searches.firstIndex(where: { $0.name == search.name }) {
            searches[index] = search
            return true
        }
        searches.append(search)
        return false
    }

    /// Delete the search named `name`, if present. Returns whether one was removed.
    @discardableResult
    public mutating func remove(name: String) -> Bool {
        guard let index = searches.firstIndex(where: { $0.name == name }) else { return false }
        searches.remove(at: index)
        return true
    }

    /// Delete the search at `index`; out-of-range is ignored.
    public mutating func remove(at index: Int) {
        guard searches.indices.contains(index) else { return }
        searches.remove(at: index)
    }

    /// Rename the search named `name` to `newName` — the sidebar's inline rename. Rejected
    /// (returns `false`, leaving the list unchanged) when `newName` is empty or already names a
    /// *different* search, so a rename can never collapse two entries into one. Renaming to the
    /// same name is a no-op success.
    @discardableResult
    public mutating func rename(name: String, to newName: String) -> Bool {
        guard let index = searches.firstIndex(where: { $0.name == name }) else { return false }
        guard !newName.isEmpty else { return false }
        guard !searches.contains(where: { $0.name == newName }) || newName == name else {
            return false
        }
        searches[index].name = newName
        return true
    }

    /// Reorder: pull the search out of `source` and reinsert it so it lands at `destination` in
    /// the *resulting* list (Array semantics, matching the favorites/workspace reorder).
    public mutating func move(from source: Int, to destination: Int) {
        guard searches.indices.contains(source) else { return }
        let search = searches.remove(at: source)
        searches.insert(search, at: min(max(destination, 0), searches.count))
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case searches
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Route decoding through the de-duplicating initializer so a legacy/corrupt store is
        // sanitized on the way back in.
        self.init(searches: try container.decode([SavedSearch].self, forKey: .searches))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(searches, forKey: .searches)
    }
}
