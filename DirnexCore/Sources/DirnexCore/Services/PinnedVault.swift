import Foundation

/// What brings back a pinned folder whose vault is locked right now.
///
/// An unlocked vault is a volume under `/Volumes/<its volume name>`, so a pin inside one is an ordinary
/// local path, and locking the vault leaves the pin pointing at a volume nothing is mounted at: the shape
/// ``PinnedShare`` answers for a share. Reported 2026-11-17: picking a pin inside a locked vault asked the
/// saved SMB server for a share named after the vault's volume, and the NAS answered that it offered none,
/// while the pin's own sidebar mark showed the vault's shut padlock.
///
/// Pure, like ``PinnedShare``: the caller reads the mount table and the saved vaults, and unlocks.
public enum PinnedVault {
    /// The saved vault a pin on the unmounted volume `volume` is in, or `nil` when it is in none.
    ///
    /// The rule is the one the pin's mark is drawn by
    /// (``LocationSource/ofPin(_:mounts:vaultMountPoints:vaultVolumeNames:home:isInternalVolume:isSymlink:)``),
    /// because the mark says where a pick will go. A pin that recorded its share is on that share,
    /// whatever vault shares the volume's name. Any other pin is in the saved vault of that volume name,
    /// the first in sidebar order, and no saved server is asked for a share of that name. Nothing on a
    /// vault's pin says it is one, so the name is all the pick has to go on, as it is for the mark.
    public static func vault(
        for entry: FavoriteEntry,
        volume: String,
        among vaults: [VaultLocation]
    ) -> VaultLocation? {
        guard entry.serverEndpoint?.smbShare == nil else { return nil }
        return vaults.first { $0.volumeName == volume }
    }
}
