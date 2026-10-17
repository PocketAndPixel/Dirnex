import AppKit
import DirnexCore

/// Unlock Vault in the right-click menu, under Open (2026-10-17).
///
/// Go ▸ Unlock Vault aims at the row under the cursor; this is the same command aimed at the row the
/// menu was opened on. The two share both halves of the rule — which rows count as an image
/// (``vaultImage(_:)``) and what vault such a row names (`VaultLocation(lockedImage:)`) — and both end
/// in the window's one unlock funnel, so the menu cannot open a vault the command would refuse or
/// remember it under another name.
extension PanelViewController {
    /// `entry`, if it is an image Unlock Vault can take: a `.sparsebundle` or a `.dmg` in a real local
    /// pane. Not a results listing, whose rows are local files but whose gestures route elsewhere, and
    /// not an archive or a server, where there is nothing `hdiutil` could attach.
    ///
    /// Any image, not only a saved vault: unlocking one is how it gets *into* the sidebar. That is the
    /// difference from Enter (`savedVault(for:)`), which is pressed on everything and so must not
    /// attach a stranger's `.dmg`.
    func vaultImage(_ entry: FileEntry?) -> FileEntry? {
        guard panel.path.backend == .local, !isVirtualDirectory, let entry,
              DiskImageArguments.Kind.isImageName(entry.name) else { return nil }
        return entry
    }

    /// The item, or `nil` where the menu is not about exactly one image — left out rather than
    /// grayed, like Show in Finder over a server's file, since it would be a gray line on nearly every
    /// right-click there is.
    ///
    /// The title is the registry's, so it reads and translates as the Go menu's does. The vault is
    /// captured as the menu is built, the rule docs/NOTES.md ▸ Key equivalents, key monitors and menus
    /// records for right-click items: a click inside a marked set leaves the cursor where it was, so a
    /// responder-chain command would unlock whatever the *cursor* is on rather than the row clicked.
    func unlockVaultItem() -> NSMenuItem? {
        let targets = selectionTargets()
        guard targets.count == 1, let image = vaultImage(targets.first),
              let title = LocalizedCatalog.command(for: "go.unlockVault")?.title else { return nil }
        let item = NSMenuItem(
            title: title,
            action: #selector(unlockContextVault(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = VaultLocation(lockedImage: image)
        return item
    }

    /// Hand the captured vault to the window, to be shown in this pane — where the command, run from
    /// this pane, would show it too.
    @objc private func unlockContextVault(_ sender: NSMenuItem) {
        guard let vault = sender.representedObject as? VaultLocation else { return }
        host?.panelRequestsVaultOpen(vault, showingIn: self, inNewTab: false)
    }
}

extension VaultLocation {
    /// The vault an image file names, before anything is known about it.
    ///
    /// Nothing can be asked of a locked image — the volume name lives inside the encrypted
    /// filesystem — so the file's own name stands in until an attach reports the real mount, which
    /// is where `openVault` corrects it. A saved vault's stored name wins over this one anyway: the
    /// unlock funnel resolves against `VaultStore` first (`withUnlockedVault`).
    init(lockedImage entry: FileEntry) {
        self.init(
            imagePath: entry.path.path,
            volumeName: (entry.name as NSString).deletingPathExtension
        )
    }
}
