import DirnexCore
import Foundation

/// App-wide persistence for saved searches (PLAN.md §M4 "Saved searches as virtual folders in
/// the places strip"). One shared list across every window, stored as boring JSON in
/// `UserDefaults` like `HotlistStore` / `WorkspaceStore` (PLAN.md §2 "JSON/plist for config").
///
/// Read fresh each time something needs it (the sidebar rebuild, the Save flow), and every
/// mutation posts `didChangeNotification` so an open sidebar — in this window or another —
/// re-renders its Searches section without any live-observation plumbing.
enum SavedSearchStore {
    private static let key = "Dirnex.savedSearches"

    /// Posted after any `save` so sidebars rebuild their Searches section. Delivered on the
    /// main thread (all mutations happen on the main actor).
    static let didChangeNotification = Notification.Name("Dirnex.savedSearchesDidChange")

    static func load() -> SavedSearches {
        guard let data = UserDefaults.standard.data(forKey: key),
              let searches = try? JSONDecoder().decode(SavedSearches.self, from: data) else {
            return SavedSearches()
        }
        return searches
    }

    static func save(_ searches: SavedSearches) {
        guard let data = try? JSONEncoder().encode(searches) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
