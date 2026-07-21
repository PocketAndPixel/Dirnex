import DirnexCore
import Foundation

/// App-wide persistence for the Favorites list — the pinned folders shown in the sidebar's
/// Favorites section and the Ctrl+D popup (PLAN.md §M3 "pin, reorder, jump"). One shared list
/// across every window, stored as boring JSON in `UserDefaults` like `TabPersistence` and the
/// command recents (PLAN.md §2 "JSON/plist for config"). Read fresh each time the menu opens, so
/// an edit — in this window or another — shows up on the next Ctrl+D without any live-observation
/// plumbing.
enum FavoritesStore {
    private static let key = "Dirnex.favorites"
    /// Set once the standard places have been merged into the pin list. The seed is a one-time
    /// migration, never a per-launch top-up: a user who removes Documents from their sidebar must
    /// not find it back tomorrow morning.
    private static let seededKey = "Dirnex.favoritesSeeded"

    /// Posted after any `save` so sidebars rebuild their Favorites section — in this window or
    /// another (PLAN.md §M8). Delivered on the main thread (all mutations happen on the main
    /// actor), matching `SavedSearchStore` / `UserScriptStore`.
    static let didChangeNotification = Notification.Name("Dirnex.favoritesDidChange")

    static func load() -> Favorites {
        guard let data = UserDefaults.standard.data(forKey: key),
              let favorites = try? JSONDecoder().decode(Favorites.self, from: data) else {
            return Favorites()
        }
        return favorites
    }

    static func save(_ favorites: Favorites) {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Merge the standard places into the pin list, once ever (PLAN.md §M8, and the §7 seeding
    /// question resolved 2026-07-20: standard places lead, existing pins follow).
    ///
    /// The flag is set even when the merge changes nothing, so this is genuinely once — a fresh
    /// install whose `~` has no Desktop yet must not re-seed later, or the sidebar would grow rows
    /// on some arbitrary future launch. Ordering and de-duplication are `Favorites.prepend`'s job;
    /// all that lives here is the once-ness and the write.
    static func seedStandardPlacesIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)

        var favorites = load()
        if favorites.prepend(SidebarLocations.favorites().map(FavoriteEntry.init(place:))) {
            save(favorites)
        }
    }
}
