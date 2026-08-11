import AppKit
import DirnexCore

/// Renaming a vault (PLAN.md §M19) — the sidebar's Rename… item and F2 on a selected vault row.
///
/// **It renames the volume, not the row.** A Favorites row carries a nickname the user may set to
/// anything, because the folder underneath has its own name in the file system; a vault has no such
/// second name to nickname. `VaultLocation.volumeName` is re-derived from the mount point on every
/// unlock (`+VaultUnlock`), so a label-only rename would be silently reverted the next time the
/// vault opened — and while it lasted, the sidebar would disagree with the pane's own path bar. So
/// this runs `diskutil rename` on the real volume, and one truth serves both.
///
/// The price is that the vault has to be **unlocked**: `diskutil` addresses a volume, and a locked
/// vault has none. Rather than gray the item out on a locked row — which answers a user's question
/// with silence — the rename goes through `withUnlockedVault`, which is silent when the passphrase
/// is in the Keychain and prompts when it is not. The vault stays unlocked afterwards, which the
/// row's open padlock says plainly.
///
/// The image file keeps its name throughout. That is deliberate: `VaultLocation.volumeName`'s own
/// doc comment notes the file name is the one thing a user may have made deliberately unrevealing,
/// so a gesture aimed at the label must not rewrite it.
extension BrowserWindowController {
    func sidebar(_ sidebar: SidebarViewController, didRequestRenameOf vault: VaultLocation) {
        renameVault(vault)
    }

    /// Ask for a name, then unlock if needed and apply it.
    ///
    /// The name is asked for **first**, before any unlock, so the common case is one dialog and the
    /// passphrase prompt — when it comes at all — arrives as machinery behind a decision already
    /// made, rather than as a toll gate before one.
    func renameVault(_ vault: VaultLocation) {
        promptForVaultName(current: vault.volumeName) { [weak self] typed in
            guard let self, let typed else { return }
            let name = VolumeName.normalized(typed)
            // An empty field is a cancel, not an error — the same reading the favorites rename
            // gives it. So is a name that did not change: there is nothing to do and nothing to say.
            guard !name.isEmpty, name != vault.volumeName else { return }
            guard VolumeName.isValid(name) else { return presentVaultError(.invalidVolumeName) }
            withUnlockedVault(vault) { [weak self] mountPoint in
                self?.applyRename(vault, at: mountPoint, to: name)
            }
        }
    }

    // MARK: - Sheet

    private func promptForVaultName(
        current: String,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Rename Vault",
            comment: "Title of the dialog that renames a vault's volume."
        )
        alert.informativeText = String(
            localized: """
            This renames the volume itself, so the vault has to be unlocked first. Its image file \
            keeps the name it has.
            """,
            comment: "Body of the rename-vault dialog, saying what is and isn’t renamed."
        )
        alert.addButton(withTitle: String(
            localized: "Rename",
            comment: "Confirm button of a rename dialog."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.keepToOneLine()
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let answer = { (response: NSApplication.ModalResponse) in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: answer)
            field.selectText(nil)
        } else {
            answer(alert.runModal())
        }
    }

    // MARK: - Apply

    private func applyRename(_ vault: VaultLocation, at mountPoint: String, to name: String) {
        SidebarRowActivity.shared.begin(vault.resolvedImagePath)
        let imagePath = vault.imagePath
        Task { [weak self] in
            defer { SidebarRowActivity.shared.end(vault.resolvedImagePath) }
            do {
                let landed = try await Task.detached(priority: .userInitiated) {
                    try DiskImageRunner.renameVolume(mountPoint: mountPoint, to: name)
                    // Where the volume *actually* ended up, asked rather than assumed: a name
                    // already in use still renames, and remounts at `/Volumes/<name> 1` (probed),
                    // and a `/` in the name reaches the path as `:`.
                    return DiskImageMount.isMounted(
                        imageAtPath: imagePath,
                        in: DiskImageRunner.attachedImages()
                    )
                }.value
                guard let self, let landed else { throw VaultError.couldNotRename }
                adoptRenamedVolume(vault, from: mountPoint, to: landed)
            } catch {
                self?.presentVaultError((error as? VaultError) ?? .couldNotRename)
            }
        }
    }

    /// Catch everything holding the old mount point up with the volume's new one.
    ///
    /// Order matters at the top: the privacy list is what `FrecencyStore.recordVisit` asks, and the
    /// navigation below records a visit — so a pane re-pointed before `VaultMounts` had heard of the
    /// new path would write a vault's directory into the frecency index in the clear. The same race
    /// the unlock path notes, arriving from the other side.
    private func adoptRenamedVolume(_ vault: VaultLocation, from old: String, to new: String) {
        VaultMounts.shared.forget(mountPoint: old)
        VaultMounts.shared.note(mountPoint: new)

        var renamed = vault
        // Named for where it landed, not for what was typed — the same derivation the unlock path
        // makes, so the sidebar always names the folder the pane actually opens. This also writes
        // the store, which posts the change that rebuilds every window's Vaults section.
        renamed.volumeName = (new as NSString).lastPathComponent
        VaultStore.remember(renamed)

        // A pane standing inside the volume follows it, keeping whatever sub-directory it was in.
        // Panes in the *other* window are left alone for the same reason `lock` leaves them: this
        // controller owns its own two, and each window's panes re-list on their own FSEvents.
        for pane in [leftPanel, rightPanel] {
            guard pane.panel.path.backend == .local,
                  let moved = VaultPrivacy.rebase(pane.panel.path.path, from: old, to: new)
            else { continue }
            pane.navigate(to: .local(moved))
        }
    }
}
