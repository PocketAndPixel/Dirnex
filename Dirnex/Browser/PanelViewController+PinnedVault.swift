import DirnexCore
import Foundation

/// A pin inside a vault that is locked (`PinnedVault`): picking it unlocks the vault and goes in, as
/// picking a pin on an unmounted share mounts the share (`PanelViewController+PinnedShare`).
///
/// Reported 2026-11-17: such a pin asked the saved SMB server for a share named after the vault's
/// volume, and the NAS answered that it offered none, while the pin's sidebar mark showed the vault.
/// The unlock is the window's one funnel, so the Keychain's passphrase, the prompt, the privacy rules
/// and the guard on a double-click are the vault row's own.
extension PanelViewController {
    /// What picking a pin whose folder is not there does.
    enum MissingPinRoute: Equatable {
        /// Unlock the vault the pin is in, then go in.
        case unlock(VaultLocation)
        /// Mount one of these shares, then go in.
        case mount([SMBLocation])
        /// Nothing would bring it back: offer to unpin it.
        case unpin
    }

    /// The route for `entry`, in the order its sidebar mark is drawn by (`LocationSource.ofPin`): a
    /// share the pin recorded, then the saved vault of its volume's name, then the saved servers'
    /// shares of that name. Takes the saved vaults and servers rather than reading them, so a test
    /// does not read the developer's own (docs/NOTES.md ▸ Testing).
    static func missingPinRoute(
        for entry: FavoriteEntry,
        vaults: [VaultLocation],
        servers: [ServerConnection]
    ) -> MissingPinRoute {
        if let volume = PinnedShare.unmountedVolume(
            of: entry.path,
            mounted: MountTable.current(),
            isSymlink: isSymlink
        ), let vault = PinnedVault.vault(for: entry, volume: volume, among: vaults) {
            return .unlock(vault)
        }
        let shares = sharesToMount(for: entry, saved: servers)
        return shares.isEmpty ? .unpin : .mount(shares)
    }

    /// Unlock `vault` and open `entry` on it. A pane that moved on while the vault unlocked stays
    /// where it went, as it does while a pinned share mounts; that is also what answers the second
    /// click of a double-click, which waits on the same unlock (`VaultUnlocksInFlight`).
    func openPinnedVault(_ entry: FavoriteEntry, in vault: VaultLocation, inNewTab: Bool) {
        let token = loadToken
        host?.panelRequestsUnlockedVault(vault) { [weak self] mountPoint in
            guard let self, token == loadToken else { return }
            landInPinnedVault(entry, mountedAt: mountPoint, inNewTab: inNewTab)
        }
    }

    /// Open `entry`'s folder on the vault now mounted at `mountPoint`, which can differ from the
    /// volume the pin was made on (`/Volumes/Documents 1` when `/Volumes/Documents` is taken). A
    /// folder the unlocked vault does not hold really has been moved or deleted. Returns where it went.
    @discardableResult
    func landInPinnedVault(
        _ entry: FavoriteEntry,
        mountedAt mountPoint: String,
        inNewTab: Bool
    ) -> VFSPath? {
        let folder = PinnedShare.path(entry.path, onMountPoint: mountPoint)
        guard Self.directoryExists(folder) else {
            presentMissingFavoriteEntry(entry.path)
            return nil
        }
        navigate(to: folder, inNewTab: inNewTab)
        focusTable()
        return folder
    }
}
