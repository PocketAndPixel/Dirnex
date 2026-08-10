import DirnexCore
import Foundation

/// App-wide persistence for the user's vaults — the sidebar's **Vaults** section (PLAN.md §M19).
///
/// `ServerConnectionStore`'s shape exactly: one shared list across every window, boring JSON in
/// `UserDefaults` (PLAN.md §2), read fresh whenever something needs it, and a notification after
/// every mutation so an open sidebar re-renders with no live-observation plumbing.
///
/// What is stored is only the **addressing** — the image's path and the volume's name. The
/// passphrase is in the Keychain (`SecretKeychain`, keyed by `VaultLocation.keychainAccount`) and
/// never here, so this file is as safe to read as the servers list beside it.
///
/// A vault is saved when it is created and when it is first unlocked, not by a separate "add"
/// gesture: a vault you have opened is one you will open again, and Remove is one right-click away.
/// The alternative — a Vaults section you have to populate by hand — makes the common case
/// (unlock the thing I made yesterday) go through the file system every time.
enum VaultStore {
    private static let key = "Dirnex.vaults"

    /// Posted after any `save` so sidebars rebuild their Vaults section. Delivered on the main
    /// thread (all mutations happen on the main actor).
    static let didChangeNotification = Notification.Name("Dirnex.vaultsDidChange")

    static func load() -> SavedVaults {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(SavedVaults.self, from: data) else {
            return SavedVaults()
        }
        return saved
    }

    static func save(_ saved: SavedVaults) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Record `vault`, writing only if something actually changed.
    static func remember(_ vault: VaultLocation) {
        var saved = load()
        guard saved.add(vault) else { return }
        save(saved)
    }

    /// Record whether `vault` should be visible outside Dirnex while it is unlocked, writing only if
    /// the answer actually changed.
    ///
    /// Stored per vault rather than as one preference, and stored *here* rather than being derived
    /// from the live mount: a locked vault has no volume to ask, and the setting has to survive being
    /// locked or it could only ever be set while the vault was open.
    static func setShowsInFinder(_ shows: Bool, for vault: VaultLocation) {
        var saved = load()
        guard saved.setShowsInFinder(shows, forPath: vault.imagePath) else { return }
        save(saved)
    }

    /// Forget `vault` **and** its stored passphrase.
    ///
    /// The Keychain item goes with the row because nothing references it once the vault is gone, and
    /// a passphrase filed under a path would otherwise be offered for whatever ends up there next —
    /// the reason `VaultLocation.keychainAccount` documents for keying on the path at all. The image
    /// itself is untouched: forgetting a vault is not deleting one, and deleting one is
    /// unrecoverable in a way no confirmation in a sidebar context menu should be able to reach.
    static func forget(_ vault: VaultLocation) {
        SecretKeychain.removePassword(for: vault)
        var saved = load()
        guard saved.remove(imagePath: vault.imagePath) else { return }
        save(saved)
    }
}
