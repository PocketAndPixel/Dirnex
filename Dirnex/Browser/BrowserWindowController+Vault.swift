import AppKit
import DirnexCore

/// Making a vault (PLAN.md §M19 Slice 2) — the New Vault command and its sheet.
///
/// On the **window**, not a pane, for the reason the sidebar's own commands are: what happens spans
/// both panes and the sidebar. The image file is written into the pane you are standing in, the
/// unlocked volume opens in the *other* one — the dual-pane shape the whole app is built around, and
/// what you want next is to copy things in — and a row appears in the sidebar for both windows.
///
/// **There is no progress bar, and that is a measurement rather than an omission.** A sparse bundle's
/// creation is constant-time in its declared ceiling: 100 GB, 500 GB and 2 TB each took **1.02 s**
/// and each cost **34 MB** on disk, and `hdiutil -puppetstrings` emitted *no* `PERCENT:` line in any
/// of the three (it reports properly for a fixed image, which is why `DiskImageRunner` still reads
/// them). A bar that can only ever flash for a second is worse than none.
extension BrowserWindowController {
    @objc func newVault(_ sender: Any?) {
        guard let directory = focusedPanel.writeDirectory else {
            presentVaultProblem(
                title: String(
                    localized: "Can’t create a vault here",
                    comment: "Alert title when the pane has no real directory to hold a new vault."
                ),
                detail: String(
                    localized: "Open a folder on disk first.",
                    comment: "Body of the can’t-create-a-vault-here alert."
                )
            )
            return
        }
        presentVaultSheet(in: directory)
    }

    /// Whether a new vault can be made from here — a real, writable, on-disk folder. The New Vault
    /// menu item and the palette entry both gate on this, so the command is grayed rather than
    /// failing into an alert once clicked.
    var canCreateVaultHere: Bool {
        guard let directory = focusedPanel.writeDirectory else { return false }
        return directory.backend == .local && focusedPanel.backend.capabilities.contains(.write)
    }

    // MARK: - Sheet

    private func presentVaultSheet(in directory: VFSPath) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "New Vault",
            comment: "Title of the sheet that creates an encrypted vault."
        )
        alert.informativeText = String(
            localized: "Create an encrypted vault in “\(directory.lastComponent)”.",
            comment: "Body of the New Vault sheet; %@ is the folder the vault file will go in."
        )
        alert.addButton(withTitle: String(
            localized: "Create",
            comment: "Button that creates the vault."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)

        let accessory = VaultCreateAccessory.make()
        alert.accessoryView = accessory.view
        alert.window.initialFirstResponder = accessory.nameField

        // `accessory` is captured — and so kept alive — by this closure for the sheet's lifetime.
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.vaultChosen(accessory: accessory, directory: directory)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: apply)
            accessory.nameField.selectText(nil)
        } else {
            apply(alert.runModal())
        }
    }

    /// Check the passphrase pair, refuse an existing vault, and create.
    ///
    /// Both checks run on `ArchivePassphrase`, never on the fields' `String`s — the same rule the
    /// pack sheet follows, and the reason that type has a `matches` at all.
    private func vaultChosen(accessory: VaultCreateAccessory, directory: VFSPath) {
        let typed = ArchivePassphrase(accessory.passphraseField.stringValue)
        let repeated = ArchivePassphrase(accessory.confirmField.stringValue)
        guard !typed.isEmpty else { return presentVaultError(.emptyPassphrase) }
        guard typed.matches(repeated) else { return presentVaultError(.passphrasesDoNotMatch) }

        let name = accessory.name
        let path = DiskImageArguments.vaultPath(
            inDirectory: directory.path,
            named: name,
            kind: .sparseBundle
        )
        // Refused, never replaced: creating over a vault destroys every byte inside it, with no
        // Trash and no undo journal to recover from — the one confirmation this milestone must not
        // offer (PLAN.md §6).
        guard !FileManager.default.fileExists(atPath: path) else {
            return presentVaultError(.alreadyExists(name: (path as NSString).lastPathComponent))
        }
        createVault(atPath: path, named: name, megabytes: accessory.megabytes, passphrase: typed)
    }

    // MARK: - Create

    private func createVault(
        atPath path: String,
        named name: String,
        megabytes: Int,
        passphrase: ArchivePassphrase
    ) {
        let vault = VaultLocation(imagePath: path, volumeName: name)
        SidebarRowActivity.shared.begin(vault.resolvedImagePath)
        Task { [weak self] in
            defer { SidebarRowActivity.shared.end(vault.resolvedImagePath) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DiskImageRunner.create(
                        atPath: path,
                        volumeName: name,
                        kind: .sparseBundle,
                        megabytes: megabytes,
                        passphrase: passphrase
                    )
                }.value
                guard let self else { return }
                // Saved before it is opened, so a vault that creates and then fails to mount is
                // still in the sidebar to try again — rather than a file the user has to go and
                // find, holding a passphrase nothing recorded.
                VaultStore.remember(vault)
                SecretKeychain.store(passphrase: passphrase, for: vault)
                focusedPanel.refreshCurrentDirectory(selecting: .local(path))
                openVault(vault, with: passphrase, showingIn: panelCounterpart(of: focusedPanel))
            } catch {
                self?.presentVaultError((error as? VaultError) ?? .couldNotCreate)
            }
        }
    }

    // MARK: - Errors

    /// A vault failure always interrupts. Every one of them means the thing the user asked for did
    /// not happen and the screen looks exactly as it did before, so there is no other way to find
    /// out — unlike a finished pack, whose result is a file they can see.
    ///
    /// The title names *which* of the three things failed rather than saying "Vault", because the
    /// sentence under it explains a cause and the title is the only place the user is told what was
    /// being attempted — and by the time an alert appears they may have clicked something else.
    func presentVaultError(_ error: VaultError) {
        presentVaultProblem(
            title: Self.title(for: error),
            detail: LocalizedCatalog.sentence(for: error)
        )
    }

    private static func title(for error: VaultError) -> String {
        switch error {
        case .emptyPassphrase, .passphrasesDoNotMatch:
            // Shared with the pack sheet: same problem, same words, one catalog entry.
            return String(
                localized: "Check the passphrase",
                comment: "Title of the alert shown when the pack sheet's two passphrases don't match."
            )
        case .alreadyExists, .couldNotCreate:
            return String(
                localized: "Couldn’t create the vault",
                comment: "Title of the alert shown when a vault could not be created."
            )
        case .couldNotLock, .volumeInUse:
            return String(
                localized: "Couldn’t lock the vault",
                comment: "Title of the alert shown when a vault could not be unmounted."
            )
        case .incorrectPassphrase, .imageUnreadable, .couldNotUnlock:
            return String(
                localized: "Couldn’t unlock the vault",
                comment: "Title of the alert shown when a vault could not be opened."
            )
        case .invalidVolumeName, .couldNotRename:
            return String(
                localized: "Couldn’t rename the vault",
                comment: "Title of the alert shown when a vault's volume could not be renamed."
            )
        }
    }

    private func presentVaultProblem(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
