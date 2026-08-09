import Foundation

/// Tracks which saved servers are mid-connect so the sidebar can spin a busy indicator on them.
/// Connecting to an SFTP server (the home-directory probe) or mounting an SMB share is async and can
/// take several seconds; without feedback a click on a Servers row looks like it did nothing at all.
/// The connect flow marks a server `begin` the moment it kicks off that work and `end` at every
/// terminal exit — success, failure, or the pane moving on mid-connect — and the sidebar (this window
/// or another) reloads that server's row to show or hide the spinner.
///
/// Keyed by the server's *name*, which is its identity in `ServerConnectionStore` (like `SavedSearch`),
/// so a key lines up with exactly one sidebar row. Main-actor only: every caller — the connect `Task`
/// and the sidebar — already runs on the main actor.
@MainActor
final class ServerConnectionActivity {
    static let shared = ServerConnectionActivity()

    /// Posted whenever a server starts or finishes connecting, so open sidebars refresh the affected
    /// row. Carries no payload — observers read `isConnecting(_:)` for the current state.
    static let didChangeNotification = Notification.Name("Dirnex.serverConnectionActivityDidChange")

    private var connecting: Set<String> = []

    private init() {}

    /// Whether the named server currently has a connect/mount in flight.
    func isConnecting(_ name: String) -> Bool {
        connecting.contains(name)
    }

    /// Mark the named server as connecting. Idempotent — posts a change only on the first `begin`, so
    /// a redundant call doesn't churn the sidebar.
    func begin(_ name: String) {
        if connecting.insert(name).inserted { notifyChanged() }
    }

    /// Mark the named server's connect as finished. Idempotent — posts a change only when it was
    /// actually in flight.
    func end(_ name: String) {
        if connecting.remove(name) != nil { notifyChanged() }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
