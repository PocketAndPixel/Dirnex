import AppKit
import DirnexCore

/// Making a vault (PLAN.md §M19 Slice 2) — the New Vault command and its sheet.
///
/// On the **window**, not a pane, for the reason the sidebar's own commands are: what happens spans
/// both panes and the sidebar. The image file is written into the pane you are standing in, the
/// unlocked volume opens in the *other* one — the dual-pane shape the whole app is built around, and
/// what you want next is to copy things in — and a row appears in the sidebar for both windows.
/// It opens in a **new tab** there, so the folder that pane was showing is still one tab away
/// rather than replaced by a place the user never chose to leave it for.
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

    /// The sheet stays up until the vault exists: Create checks and creates while it is on screen,
    /// any failure is said under the form, and only a vault on disk (or Cancel) takes it down.
    ///
    /// Sheet-only, unlike this file's alerts: a `runModal` loop cannot be ended cleanly from the
    /// create's `Task`, and the command is the window's own, so there is always a window to hang on.
    private func presentVaultSheet(in directory: VFSPath) {
        guard let window else { return }
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
        accessory.routeCreate(through: alert.buttons[0])
        // Weak: the completion handler below owns `accessory`, and `alert` owns its view.
        accessory.onHeightChange = { [weak alert] in alert?.layout() }
        accessory.onCreate = { [weak self, weak alert, weak accessory] in
            guard let self, let alert, let accessory else { return }
            createPressed(on: alert, accessory: accessory, directory: directory)
        }

        // `accessory` is captured — and so kept alive — by this closure for the sheet's lifetime.
        // Nothing is left to do once the sheet is down: a created vault was opened before it ended.
        alert.beginSheetModal(for: window) { _ in accessory.onCreate = nil }
        accessory.nameField.selectText(nil)
    }

    /// Check the passphrase pair, refuse an existing vault, and create — saying what was wrong
    /// under the form, and putting the cursor where the fix goes, if any of it fails.
    ///
    /// Both checks run on `ArchivePassphrase`, never on the fields' `String`s — the same rule the
    /// pack sheet follows, and the reason that type has a `matches` at all.
    private func createPressed(
        on alert: NSAlert,
        accessory: VaultCreateAccessory,
        directory: VFSPath
    ) {
        let typed = ArchivePassphrase(accessory.passphraseField.stringValue)
        let repeated = ArchivePassphrase(accessory.confirmField.stringValue)
        guard !typed.isEmpty else {
            accessory.showError(LocalizedCatalog.sentence(for: VaultError.emptyPassphrase))
            alert.window.makeFirstResponder(accessory.passphraseField)
            return
        }
        guard typed.matches(repeated) else {
            // Both go: with the text hidden there is no telling which of the two was mistyped.
            accessory.passphraseField.stringValue = ""
            accessory.confirmField.stringValue = ""
            accessory.showError(LocalizedCatalog.sentence(for: VaultError.passphrasesDoNotMatch))
            alert.window.makeFirstResponder(accessory.passphraseField)
            return
        }

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
            let taken = VaultError.alreadyExists(name: (path as NSString).lastPathComponent)
            accessory.showError(LocalizedCatalog.sentence(for: taken))
            accessory.nameField.selectText(nil)
            return
        }
        accessory.showError(nil)
        createVault(
            VaultLocation(imagePath: path, volumeName: name),
            megabytes: accessory.megabytes,
            passphrase: typed,
            from: alert,
            accessory: accessory
        )
    }

    // MARK: - Create

    /// Create the image with the sheet still up and its buttons off, then take the sheet down and
    /// open the vault — or turn the buttons back on and say why not.
    private func createVault(
        _ vault: VaultLocation,
        megabytes: Int,
        passphrase: ArchivePassphrase,
        from alert: NSAlert,
        accessory: VaultCreateAccessory
    ) {
        let path = vault.imagePath
        let name = vault.volumeName
        for button in alert.buttons {
            button.isEnabled = false
        }
        SidebarRowActivity.shared.begin(vault.resolvedImagePath)
        Task { [weak self] in
            defer { SidebarRowActivity.shared.end(vault.resolvedImagePath) }
            do {
                try await BlockingWork.run {
                    Result {
                        try DiskImageRunner.create(
                            atPath: path,
                            volumeName: name,
                            kind: .sparseBundle,
                            megabytes: megabytes,
                            passphrase: passphrase
                        )
                    }
                }.get()
            } catch {
                for button in alert.buttons {
                    button.isEnabled = true
                }
                let reason = (error as? VaultError) ?? .couldNotCreate
                accessory.showError(LocalizedCatalog.sentence(for: reason))
                return
            }
            // Down first, so anything opening the vault has to say lands on the window rather than
            // on a sheet that is about to go.
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
            guard let self else { return }
            // Saved before it is opened, so a vault that creates and then fails to mount is
            // still in the sidebar to try again — rather than a file the user has to go and
            // find, holding a passphrase nothing recorded.
            VaultStore.remember(vault)
            SecretKeychain.store(passphrase: passphrase, for: vault)
            focusedPanel.refreshCurrentDirectory(selecting: .local(path))
            openVault(
                vault,
                with: passphrase,
                showingIn: panelCounterpart(of: focusedPanel),
                inNewTab: true
            )
        }
    }

    // MARK: - Errors

    /// A vault failure always interrupts. Every one of them means the thing the user asked for did
    /// not happen and the screen looks exactly as it did before, so there is no other way to find
    /// out — unlike a finished pack, whose result is a file they can see. The New Vault sheet is the
    /// exception that proves it: it is still on screen when its create fails, so it says so itself.
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
            return String(
                localized: "Check the passphrase",
                comment: "Title of the vault alert for an empty or mismatched passphrase."
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
        alert.offerFullDiskAccessSettings()
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
