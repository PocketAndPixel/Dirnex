import Foundation

/// Tracks which sidebar rows have slow work in flight, so the sidebar can spin a busy indicator on
/// them. Connecting to an SFTP server (the home-directory probe), mounting an SMB share and
/// unlocking a vault are all async and take a second or several; without feedback a click on such a
/// row looks like it did nothing at all. The flow marks a row `begin` the moment it kicks off that
/// work and `end` at every terminal exit — success, failure, or the pane moving on midway — and the
/// sidebar (this window or another) reloads that row to show or hide the spinner.
///
/// Keyed by whatever identifies the row in its own store: a server's *name* (its identity in
/// `ServerConnectionStore`, like `SavedSearch`), a vault's *resolved image path* (its identity in
/// `SavedVaults`). One key lines up with exactly one row. Main-actor only: every caller — the
/// connect/unlock `Task` and the sidebar — already runs on the main actor.
///
/// It was `ServerConnectionActivity` until vaults needed the identical set; nothing about it was
/// ever server-shaped except the name.
@MainActor
final class SidebarRowActivity {
    static let shared = SidebarRowActivity()

    /// Posted whenever a row starts or finishes working, so open sidebars refresh it. Carries no
    /// payload — observers read `isWorking(_:)` for the current state.
    static let didChangeNotification = Notification.Name("Dirnex.sidebarRowActivityDidChange")

    private var working: Set<String> = []

    private init() {}

    /// Whether the row with this identity currently has work in flight.
    func isWorking(_ id: String) -> Bool {
        working.contains(id)
    }

    /// Mark the row as working. Idempotent — posts a change only on the first `begin`, so a
    /// redundant call doesn't churn the sidebar.
    func begin(_ id: String) {
        if working.insert(id).inserted { notifyChanged() }
    }

    /// Mark the row's work as finished. Idempotent — posts a change only when it was actually in
    /// flight.
    func end(_ id: String) {
        if working.remove(id) != nil { notifyChanged() }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
