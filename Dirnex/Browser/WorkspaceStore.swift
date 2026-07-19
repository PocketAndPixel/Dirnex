import DirnexCore
import Foundation

/// App-wide persistence for named workspaces (PLAN.md §M3 "Workspaces: save/restore both
/// panels with all tabs, named, switchable from palette"). One shared collection across every
/// window, stored as boring JSON in `UserDefaults` like `HotlistStore` and the command recents
/// (PLAN.md §2 "JSON/plist for config"). Read fresh each time the menu opens or a save runs, so
/// an edit in the organizer — or in another window — shows up on the next open without any
/// live-observation plumbing.
enum WorkspaceStore {
    private static let key = "Dirnex.workspaces"

    static func load() -> Workspaces {
        guard let data = UserDefaults.standard.data(forKey: key),
              let workspaces = try? JSONDecoder().decode(Workspaces.self, from: data) else {
            return Workspaces()
        }
        return workspaces
    }

    static func save(_ workspaces: Workspaces) {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
