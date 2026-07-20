import DirnexCore
import Foundation

/// App-wide persistence for the directory hotlist (PLAN.md §M3 "Directory hotlist … pin,
/// reorder, jump"). One shared list across every window, stored as boring JSON in
/// `UserDefaults` like `TabPersistence` and the command recents (PLAN.md §2 "JSON/plist for
/// config"). Read fresh each time the menu opens, so an edit in the organizer — or in another
/// window — shows up on the next Ctrl+D without any live-observation plumbing.
enum HotlistStore {
    private static let key = "Dirnex.hotlist"
    /// Set once the standard places have been merged into the pin list. The seed is a one-time
    /// migration, never a per-launch top-up: a user who removes Documents from their sidebar must
    /// not find it back tomorrow morning.
    private static let seededKey = "Dirnex.hotlistSeeded"

    /// Posted after any `save` so sidebars rebuild their Favorites section — in this window or
    /// another (PLAN.md §M8). Delivered on the main thread (all mutations happen on the main
    /// actor), matching `SavedSearchStore` / `UserScriptStore`.
    static let didChangeNotification = Notification.Name("Dirnex.hotlistDidChange")

    static func load() -> Hotlist {
        guard let data = UserDefaults.standard.data(forKey: key),
              let hotlist = try? JSONDecoder().decode(Hotlist.self, from: data) else {
            return Hotlist()
        }
        return hotlist
    }

    static func save(_ hotlist: Hotlist) {
        guard let data = try? JSONEncoder().encode(hotlist) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Merge the standard places into the pin list, once ever (PLAN.md §M8, and the §7 seeding
    /// question resolved 2026-07-20: standard places lead, existing pins follow).
    ///
    /// The flag is set even when the merge changes nothing, so this is genuinely once — a fresh
    /// install whose `~` has no Desktop yet must not re-seed later, or the sidebar would grow rows
    /// on some arbitrary future launch. Ordering and de-duplication are `Hotlist.prepend`'s job;
    /// all that lives here is the once-ness and the write.
    static func seedStandardPlacesIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)

        var hotlist = load()
        if hotlist.prepend(SidebarLocations.favorites().map(HotlistEntry.init(place:))) {
            save(hotlist)
        }
    }
}
