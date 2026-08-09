import AppKit
import DirnexCore

/// The sidebar's **Vaults** section: the locked/unlocked row and its right-click menu (PLAN.md
/// §M19). Split out of `SidebarViewController` so that file stays under its length limit, exactly as
/// the Servers, Favorites and Tags sections are.
///
/// **The lock state is asked, never remembered.** `hdiutil` is the authority on what is attached, so
/// a `hdiutil detach` in Terminal or an eject in Finder cannot leave a row claiming a vault is open.
/// The cost is one subprocess per sidebar rebuild — measured at 12–14 ms — which is why it is asked
/// **once** for the whole section rather than once per row, and not at all when the user has no
/// vaults. Rebuilds are gesture-driven (a mount notification, a store change), not per-frame.
extension SidebarViewController {
    /// The vault list changed — one was created, unlocked for the first time, or forgotten — so the
    /// Vaults section rebuilds, in this window and every other. A full rebuild rather than a row
    /// reload, because the row *set* is what changed; the lock state comes back from `hdiutil` on
    /// the way through.
    func observeVaultChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vaultsChanged),
            name: VaultStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func vaultsChanged() {
        rebuild()
    }

    // MARK: - Rendering

    /// Where each saved vault is mounted right now, keyed by resolved image path. Empty when nothing
    /// is unlocked — and computed by `rebuild` before any cell is made, so every row in one pass
    /// reads one answer.
    static func mountPoints(of vaults: [VaultLocation]) -> [String: String] {
        guard !vaults.isEmpty else { return [:] }
        let attached = DiskImageRunner.attachedImages()
        var points: [String: String] = [:]
        for vault in vaults {
            guard let point = DiskImageMount.isMounted(
                imageAtPath: vault.imagePath,
                in: attached
            ) else { continue }
            points[vault.resolvedImagePath] = point
        }
        return points
    }

    /// Build (or reuse) a vault cell: a padlock that is open or shut, the volume's name, the image's
    /// path as a tooltip, and — when it is unlocked — the eject button that locks it.
    ///
    /// Eject rather than a second menu-only action, because an unlocked vault *is* a mounted volume
    /// and that is the affordance every other mounted thing on this Mac carries. It also puts Lock
    /// one click from the row, which matters for the gesture whose whole purpose is "I am done here".
    func vaultCell(for vault: VaultLocation) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        let isUnlocked = vaultMountPoints[vault.resolvedImagePath] != nil
        cell.configure(
            name: vault.volumeName,
            image: Self.vaultIcon(isUnlocked: isUnlocked),
            canEject: isUnlocked,
            tooltip: vault.imagePath,
            isBusy: SidebarRowActivity.shared.isWorking(vault.resolvedImagePath)
        )
        cell.onEject = isUnlocked
            ? { [weak self] in
                guard let self else { return }
                delegate?.sidebar(self, didRequestLockOf: vault)
            }
            : nil
        return cell
    }

    /// An open or shut padlock — the one distinction the row exists to draw, and the one a user
    /// reads without looking. Template, so the source list tints it like every glyph beside it.
    private static func vaultIcon(isUnlocked: Bool) -> NSImage {
        templateSymbol(
            isUnlocked ? "lock.open.fill" : "lock.fill",
            pointSize: 14,
            describedAs: isUnlocked
                ? String(
                    localized: "Unlocked vault",
                    comment: "Accessibility label for an unlocked vault's sidebar glyph."
                )
                : String(
                    localized: "Locked vault",
                    comment: "Accessibility label for a locked vault's sidebar glyph."
                )
        )
    }

    // MARK: - Right-click menu

    /// Populate `menu` with Unlock **or** Lock (never both — a vault is in one state), then Remove.
    func buildVaultMenu(_ menu: NSMenu, for vault: VaultLocation) {
        let isUnlocked = vaultMountPoints[vault.resolvedImagePath] != nil
        menu.addItem(vaultMenuItem(
            isUnlocked
                ? String(
                    localized: "Open",
                    comment: "Vault context-menu item: browse an already-unlocked vault."
                )
                : String(
                    localized: "Unlock",
                    comment: "Vault context-menu item: ask for the passphrase and mount the vault."
                ),
            #selector(unlockVaultItem(_:)),
            vault
        ))
        if isUnlocked {
            menu.addItem(vaultMenuItem(
                String(
                    localized: "Lock",
                    comment: "Vault context-menu item: unmount the vault."
                ),
                #selector(lockVaultItem(_:)),
                vault
            ))
        }
        menu.addItem(.separator())
        menu.addItem(vaultMenuItem(
            String(
                localized: "Remove from Sidebar",
                comment: """
                Vault context-menu item: forget the vault. Deliberately not just "Remove" — the \
                vault's own file is untouched, and "Remove" beside a padlock reads as "destroy it".
                """
            ),
            #selector(removeVaultItem(_:)),
            vault
        ))
    }

    /// One management item, carrying the vault itself rather than an index — the store can change
    /// while the menu is open, and an index would then act on a different vault.
    private func vaultMenuItem(
        _ title: String,
        _ action: Selector,
        _ vault: VaultLocation
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = vault.imagePath
        return item
    }

    private func vault(from sender: NSMenuItem) -> VaultLocation? {
        guard let path = sender.representedObject as? String else { return nil }
        return VaultStore.load().vault(atPath: path)
    }

    @objc private func unlockVaultItem(_ sender: NSMenuItem) {
        guard let vault = vault(from: sender) else { return }
        delegate?.sidebar(self, didActivateVault: vault)
    }

    @objc private func lockVaultItem(_ sender: NSMenuItem) {
        guard let vault = vault(from: sender) else { return }
        delegate?.sidebar(self, didRequestLockOf: vault)
    }

    @objc private func removeVaultItem(_ sender: NSMenuItem) {
        guard let vault = vault(from: sender) else { return }
        confirmRemoveVault(vault)
    }

    /// Confirm before forgetting a vault.
    ///
    /// The confirmation says what is *not* happening, because that is the fear: a padlock in a list
    /// with a Remove next to it reads as "destroy the contents", and the one thing a user must be
    /// sure of before clicking is that their files are still there afterwards.
    private func confirmRemoveVault(_ vault: VaultLocation) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Remove “\(vault.volumeName)” from the sidebar?",
            comment: "Vault remove confirmation title; %@ is the vault's volume name."
        )
        alert.informativeText = String(
            localized: """
            The vault file stays where it is and nothing inside it is deleted. Its saved passphrase \
            is removed from your Keychain, so you’ll be asked for it next time.
            """,
            comment: "Body of the remove-vault confirmation."
        )
        alert.addButton(withTitle: String(
            localized: "Remove",
            comment: "Confirm button that forgets a vault."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)

        let commit = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            VaultStore.forget(vault)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: commit)
        } else {
            commit(alert.runModal())
        }
    }
}
