import DirnexCore
import Foundation

/// App-wide persistence for user scripts — the shell actions surfaced in the ⌘K palette and the
/// right-click **Scripts ▸** submenu (PLAN.md §M6 "user actions — shell scripts receiving selection
/// as argv/env"). One shared list across every window, stored as boring JSON in `UserDefaults` like
/// `ServerConnectionStore` / `SavedSearchStore` / `WorkspaceStore` (PLAN.md §2 "JSON/plist for
/// config"). A `UserScript` is secret-free by construction (it holds only its own shell text and
/// metadata — no path or credential), so the JSON is safe to persist as-is.
///
/// Read fresh each time something needs it (the palette rebuild, the context submenu, the organizer),
/// and every mutation posts `didChangeNotification` so any open surface re-renders without live
/// observation plumbing.
enum UserScriptStore {
    private static let key = "Dirnex.userScripts"

    /// Posted after any `save` so palettes and menus rebuild. Delivered on the main thread (all
    /// mutations happen on the main actor).
    static let didChangeNotification = Notification.Name("Dirnex.userScriptsDidChange")

    static func load() -> UserScripts {
        guard let data = UserDefaults.standard.data(forKey: key),
              let scripts = try? JSONDecoder().decode(UserScripts.self, from: data) else {
            return UserScripts()
        }
        return scripts
    }

    static func save(_ scripts: UserScripts) {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
