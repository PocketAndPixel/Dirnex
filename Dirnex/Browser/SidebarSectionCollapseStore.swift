import DirnexCore
import Foundation

/// App-wide persistence for which sidebar sections are folded shut (PLAN.md §M8 "Disclosure
/// triangles, per-section state persisted"). Boring JSON in `UserDefaults`, like `FavoritesStore`
/// and `SavedSearchStore` beside it.
///
/// **One state shared by every window, not one per window.** "Persisted" and "per window" pull in
/// opposite directions — with a state per window there is no answer to *which* window's sidebar
/// gets written on quit. This matches every other sidebar store; the one genuinely per-window
/// piece of sidebar state, `showsAllTags`, is deliberately not persisted at all.
enum SidebarSectionCollapseStore {
    private static let key = "Dirnex.sidebarCollapsedSections"

    /// Posted after any `save` so every open sidebar folds in step.
    static let didChangeNotification = Notification.Name("Dirnex.sidebarSectionCollapseDidChange")

    static func load() -> SidebarSectionCollapse {
        guard let data = UserDefaults.standard.data(forKey: key),
              let collapse = try? JSONDecoder().decode(SidebarSectionCollapse.self, from: data) else {
            return SidebarSectionCollapse()
        }
        return collapse
    }

    static func save(_ collapse: SidebarSectionCollapse) {
        guard let data = try? JSONEncoder().encode(collapse) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
