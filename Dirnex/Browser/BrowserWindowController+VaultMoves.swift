import AppKit
import DirnexCore

/// Keeping a saved vault attached to its image file when the user moves that file around in a pane
/// (PLAN.md §M19).
///
/// A vault is addressed by its image's path twice over — the sidebar's saved list, and the Keychain
/// account holding its passphrase — so an F2 on the `.sparsebundle`, an F6 that moves it, or a move
/// of any folder above it used to leave the row pointing at nothing and the passphrase filed under a
/// path nothing would ever ask about again. It failed in the quiet direction: the row looked
/// completely normal until it was clicked, and then reported that the image "may have been moved or
/// damaged" — true, and unhelpful, since Dirnex was the thing that moved it.
///
/// The hook is `UndoRecord`, because it is the one funnel every rename, move, multi-rename and sync
/// already reports through, and because it names *both* ends of each move — which is what lets undo
/// and redo work with no direction bookkeeping (``VaultImageMove`` explains the symmetry). What is
/// followed and what is deliberately left alone — a trashed vault, a copy, a remote destination —
/// is decided there, in the tested core; this half is the file system and the Keychain.
extension BrowserWindowController {
    /// A file operation just landed: re-point any saved vault whose image it moved.
    ///
    /// The candidates are only candidates — the disk decides. Asking "is the vault's image gone, and
    /// is something at the other end?" is what makes a half-applied undo come out right, since each
    /// vault is judged on where its own image actually is rather than on what the operation was
    /// nominally doing.
    func followVaultImageMoves(in record: UndoRecord) {
        let manager = FileManager.default
        for candidate in VaultImageMove.candidates(in: record, vaults: VaultStore.load()) {
            guard !manager.fileExists(atPath: candidate.vault.imagePath),
                  manager.fileExists(atPath: candidate.destination)
            else { continue }
            adoptMovedVaultImage(candidate.vault, at: candidate.destination)
        }
    }

    private func adoptMovedVaultImage(_ vault: VaultLocation, at newPath: String) {
        var moved = vault
        moved.imagePath = newPath

        // An image renamed while it was *attached* keeps being reported by `hdiutil` under its old
        // path until it is detached (probed), so this has to be recorded before the store moves —
        // afterwards there is nothing left that knows which mounted image is this vault's. Asked
        // rather than assumed, since the ordinary case is a locked vault and needs no alias at all.
        if let mountPoint = DiskImageMount.isMounted(
            imageAtPath: vault.imagePath,
            in: DiskImageRunner.attachedImages()
        ), !mountPoint.isEmpty {
            MovedVaultImages.shared.note(movedFrom: vault.imagePath, to: newPath)
        }

        // The passphrase travels with the file. `keychainAccount` is the resolved image path, so
        // leaving it behind orphans it twice over: this vault would ask for a passphrase that is
        // sitting right there, and the stale item would be offered to whatever occupies the old path
        // next — the exact hazard `VaultLocation.keychainAccount` keys on the path to avoid.
        if let passphrase = SecretKeychain.passphrase(for: vault) {
            SecretKeychain.removePassword(for: vault)
            SecretKeychain.store(passphrase: passphrase, for: moved)
        }

        // `move` rather than remove-and-add, so the row keeps its place in the Vaults section: a
        // rename is about a file name and has no business reordering the sidebar. The store's own
        // change notification rebuilds every window's list.
        var saved = VaultStore.load()
        saved.move(imagePath: vault.imagePath, to: newPath)
        VaultStore.save(saved)
    }
}
