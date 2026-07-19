import DirnexCore
import Foundation

/// App-wide persistence for saved server connections — the sidebar's **Servers** section
/// (PLAN.md §M5 "one place that keeps every saved remote — SFTP and SMB alike"). One shared list
/// across every window, stored as boring JSON in `UserDefaults` like `SavedSearchStore` /
/// `WorkspaceStore` (PLAN.md §2 "JSON/plist for config"). Only coordinates and the auth *method*
/// are persisted — never a secret (SFTP/SMB passwords stay in the Keychain), so the JSON is safe.
///
/// Read fresh each time something needs it (the sidebar rebuild, the connect/save flow), and every
/// mutation posts `didChangeNotification` so an open sidebar — in this window or another —
/// re-renders its Servers section without any live-observation plumbing.
enum ServerConnectionStore {
    private static let key = "Dirnex.serverConnections"

    /// Posted after any `save` so sidebars rebuild their Servers section. Delivered on the
    /// main thread (all mutations happen on the main actor).
    static let didChangeNotification = Notification.Name("Dirnex.serverConnectionsDidChange")

    static func load() -> ServerConnections {
        guard let data = UserDefaults.standard.data(forKey: key),
              let connections = try? JSONDecoder().decode(ServerConnections.self, from: data) else {
            return ServerConnections()
        }
        return connections
    }

    static func save(_ connections: ServerConnections) {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
