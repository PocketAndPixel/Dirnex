import DirnexCore
import Foundation

/// App-wide persistence for the order of the sidebar's **Cloud** section — iCloud Drive and the
/// provider mounts under `~/Library/CloudStorage`, which the user can drag into whatever order they
/// like (PLAN.md §M8, §M10). One shared order across every window, stored as boring JSON in
/// `UserDefaults` like `FavoritesStore` and `TabPersistence` (PLAN.md §2 "JSON/plist for config").
///
/// What is stored is the *order*, not the rows: the rows themselves are discovered by a scan on
/// every rebuild, so this holds only their identities (see `SidebarItemOrder`). An order naming a
/// mount that has since been signed out is kept, not pruned — it is what puts the account back
/// where the user had it if it returns.
enum CloudSectionOrderStore {
    private static let key = "Dirnex.cloudSectionOrder"

    /// Posted after any `save` so every open sidebar re-sorts its Cloud section — in this window or
    /// another, matching `FavoritesStore`. Delivered on the main thread (all mutations happen on the
    /// main actor).
    static let didChangeNotification = Notification.Name("Dirnex.cloudSectionOrderDidChange")

    static func load() -> SidebarItemOrder {
        guard let data = UserDefaults.standard.data(forKey: key),
              let order = try? JSONDecoder().decode(SidebarItemOrder.self, from: data) else {
            return SidebarItemOrder()
        }
        return order
    }

    static func save(_ order: SidebarItemOrder) {
        guard let data = try? JSONEncoder().encode(order) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
