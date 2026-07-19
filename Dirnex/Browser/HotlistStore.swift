import DirnexCore
import Foundation

/// App-wide persistence for the directory hotlist (PLAN.md §M3 "Directory hotlist … pin,
/// reorder, jump"). One shared list across every window, stored as boring JSON in
/// `UserDefaults` like `TabPersistence` and the command recents (PLAN.md §2 "JSON/plist for
/// config"). Read fresh each time the menu opens, so an edit in the organizer — or in another
/// window — shows up on the next Ctrl+D without any live-observation plumbing.
enum HotlistStore {
    private static let key = "Dirnex.hotlist"

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
    }
}
