import Foundation

/// The vault unlocks under way, and every request waiting on each one.
///
/// **A double-click on a locked vault is two unlocks.** The sidebar acts on every click, so the
/// second one arrives while the first `hdiutil attach` is still running — and two attaches of one
/// image do not share: probed on macOS 26, the first mounts and the second exits 1 with
/// `attach failed - Resource temporarily unavailable`, which reads as ``VaultError/couldNotUnlock``.
/// The vault opened *and* the user was told it couldn't be. A second request therefore joins the one
/// in flight instead of starting its own, and is answered with the same mount point when it lands.
///
/// Joined rather than dropped, so a request made mid-unlock means what it means on an unlocked
/// vault: a double-click on an open one navigates twice, and a Rename picked while the unlock is
/// still running gets its vault. Only the overlap needs this: a request after the first one settled
/// finds the vault mounted, and even an attach of a mounted image exits 0 with its mount point
/// (probed the same day).
///
/// The entry lives from the first request to the end of the whole unlock, passphrase prompt
/// included: a click while that prompt is up must not raise a second one. Shared across windows,
/// since the collision is `hdiutil`'s and does not care which window asked. Keyed by resolved image
/// path, the identity ``SidebarRowActivity`` uses for the same row.
@MainActor
final class VaultUnlocksInFlight {
    static let shared = VaultUnlocksInFlight()

    private var waiting: [String: [@MainActor (String) -> Void]] = [:]

    /// `internal` rather than `private` only so a test can have a registry of its own.
    init() {}

    /// Wait for the unlock of the vault `id`, starting one if none is under way.
    ///
    /// `true` hands the caller the unlock to run, and it must ``settle(_:mountedAt:)`` it on every
    /// exit. `false` means one is already running and `body` will be answered by it.
    func join(_ id: String, then body: @escaping @MainActor (String) -> Void) -> Bool {
        if waiting[id] != nil {
            waiting[id]?.append(body)
            return false
        }
        waiting[id] = [body]
        return true
    }

    /// The unlock of `id` is over: answer everyone waiting with `mountPoint`, or no one when it is
    /// `nil` (cancelled, refused, or failed with its own alert already raised).
    ///
    /// The entry goes before any waiter runs, so a waiter that unlocks again starts afresh.
    func settle(_ id: String, mountedAt mountPoint: String?) {
        guard let bodies = waiting.removeValue(forKey: id), let mountPoint else { return }
        for body in bodies {
            body(mountPoint)
        }
    }
}
