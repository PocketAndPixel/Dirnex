import AppKit
import DirnexCore

/// Pack (Alt+F5) — TC's "create an archive from the selected files" (PLAN.md §M4 "pack via
/// F5-with-archive-target"), the inverse of F5 copy-out from inside an archive.
///
/// Packing isn't a cross-backend copy through `CopyEngine`; it writes one archive file directly.
/// The marked/cursor items of this (real, local) pane are packed into the *other* pane's folder —
/// the same default destination as F5. A small sheet picks the base name, container format and,
/// for a zip, a passphrase; the new archive lands selected in the other pane, immediately browsable
/// (its suffix is one `ArchiveType.isBrowsable` recognizes).
///
/// **Two run paths, and the split is the libarchive boundary M19 drew** (PLAN.md §M19). An ordinary
/// pack is one `bsdtar` spawn on a detached task, as it always was. An *encrypted* pack goes on the
/// operation queue as `FileOperation.Kind.pack`, because `bsdtar` cannot be handed a passphrase
/// without putting it in `argv` where any `ps` can read it — so the encrypted path runs through
/// libarchive, which takes the passphrase in memory, and having gone there it gets the queue's
/// determinate bar and cancel for free. AES-256 over a folder of photographs is minutes.
extension PanelViewController {
    @objc func packSelection(_ sender: Any?) {
        beginArchivePacking()
    }

    /// Whether this pane can be a pack *source*: a real on-disk folder (not a read-only archive or
    /// a virtual search-results listing), where every selected item shares one parent directory so
    /// a single `bsdtar -C` covers them.
    var canPackFromHere: Bool {
        panel.path.backend == .local && !isVirtualDirectory
    }

    /// Validate the marked/cursor items, resolve the destination (the other pane), and raise the
    /// pack sheet. Re-checks `canPackFromHere` since Alt+F5 can arrive via the key model.
    func beginArchivePacking() {
        guard canPackFromHere else { return }
        let sources = selectionTargets()
        guard !sources.isEmpty, let destPane = host?.panelCounterpart(of: self) else { return }

        // The archive is written straight into the other pane, so it must be a real writable folder.
        guard destPane.panel.path.backend == .local,
              destPane.backend.capabilities.contains(.write) else {
            presentOperationFailure(
                message: String(localized: "Can’t pack here"),
                detail: String(
                    localized: "Open a folder on disk in the other panel to hold the new archive."
                )
            )
            return
        }
        let defaults = PackAccessory.Defaults(
            baseName: ArchivePacking.defaultBaseName(
                forSourceNames: sources.map(\.name),
                sourceDirectoryName: panel.path.lastComponent
            )
        )
        presentPackSheet(sources: sources, destinationPane: destPane, defaults: defaults)
    }

    // MARK: - Sheet

    private func presentPackSheet(
        sources: [FileEntry],
        destinationPane: PanelViewController,
        defaults: PackAccessory.Defaults
    ) {
        let destination = destinationPane.panel.path
        let alert = NSAlert()
        alert.messageText = sources.count == 1
            ? String(localized: "Pack “\(sources[0].name)”")
            : String(localized: "Pack \(sources.count) items")
        alert.informativeText = String(
            localized: "Create an archive in “\(destination.lastComponent)”."
        )
        alert.addButton(withTitle: String(localized: "Pack"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let accessory = PackAccessory.make(defaults)
        alert.accessoryView = accessory.view
        alert.window.initialFirstResponder = accessory.nameField

        // `accessory` is captured (and so kept alive) by this closure for the sheet's lifetime,
        // which is what keeps the popups' target — the accessory itself — from being deallocated
        // under it: `NSControl.target` is weak.
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.packChosen(
                accessory: accessory,
                sources: sources,
                destinationPane: destinationPane
            )
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
            accessory.nameField.selectText(nil)
        } else {
            apply(alert.runModal())
        }
    }

    /// Read the sheet back, check the passphrase pair, and go on to the conflict guard.
    ///
    /// A rejected passphrase re-raises the sheet with every *other* choice intact rather than
    /// dropping the user back into the pane — they have already picked a name, a format and a
    /// level, and none of that is what they got wrong. The passphrase fields come back empty,
    /// which is the one thing they do have to type again.
    private func packChosen(
        accessory: PackAccessory,
        sources: [FileEntry],
        destinationPane: PanelViewController
    ) {
        let encryption = accessory.encryption
        let defaults = PackAccessory.Defaults(
            baseName: accessory.nameField.stringValue,
            format: accessory.format,
            level: accessory.level,
            encryption: encryption,
            namePrivacy: accessory.namePrivacy
        )
        var passphrase: ArchivePassphrase?
        if encryption.isEncrypted {
            let typed = ArchivePassphrase(accessory.passphraseField.stringValue)
            let repeated = ArchivePassphrase(accessory.confirmField.stringValue)
            // Both checks run on `ArchivePassphrase`, never on the two fields' `String`s: comparing
            // the text at this call site is exactly what that type exists to remove the reason for.
            guard !typed.isEmpty else {
                return retryPackSheet(
                    after: .emptyPassphrase,
                    sources: sources,
                    destinationPane: destinationPane,
                    defaults: defaults
                )
            }
            guard typed.matches(repeated) else {
                return retryPackSheet(
                    after: .passphrasesDoNotMatch,
                    sources: sources,
                    destinationPane: destinationPane,
                    defaults: defaults
                )
            }
            passphrase = typed
        }

        let name = ArchivePacking.archiveFileName(
            baseName: accessory.nameField.stringValue,
            format: defaults.format
        )
        confirmAndPack(
            sources: sources,
            archiveName: name,
            defaults: defaults,
            passphrase: passphrase,
            destinationPane: destinationPane
        )
    }

    private func retryPackSheet(
        after error: EncryptedArchiveError,
        sources: [FileEntry],
        destinationPane: PanelViewController,
        defaults: PackAccessory.Defaults
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Check the passphrase",
            comment: "Title of the alert shown when the pack sheet's two passphrases don't match."
        )
        alert.informativeText = LocalizedCatalog.sentence(for: error)
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        let reopen: (NSApplication.ModalResponse) -> Void = { [weak self] _ in
            self?.presentPackSheet(
                sources: sources,
                destinationPane: destinationPane,
                defaults: defaults
            )
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: reopen)
        } else {
            reopen(alert.runModal())
        }
    }

    // MARK: - Conflict + run

    /// Guard an existing file at the target before packing — both writers would replace it — then
    /// pack. A collision raises a Replace/Cancel confirmation (default Cancel).
    private func confirmAndPack(
        sources: [FileEntry],
        archiveName: String,
        defaults: PackAccessory.Defaults,
        passphrase: ArchivePassphrase?,
        destinationPane: PanelViewController
    ) {
        let target = destinationPane.panel.path.appending(archiveName)
        let run: () -> Void = { [weak self] in
            self?.runPack(
                sources: sources,
                target: target,
                defaults: defaults,
                passphrase: passphrase,
                destinationPane: destinationPane
            )
        }
        guard (try? destinationPane.backend.stat(at: target)) != nil else {
            run()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(archiveName)” already exists")
        alert.informativeText = String(
            localized: "Replace the existing archive in “\(destinationPane.panel.path.lastComponent)”?"
        )
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let proceed: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            run()
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    /// Send the pack down whichever of the two paths its cipher chose.
    private func runPack(
        sources: [FileEntry],
        target: VFSPath,
        defaults: PackAccessory.Defaults,
        passphrase: ArchivePassphrase?,
        destinationPane: PanelViewController
    ) {
        guard let passphrase, defaults.encryption.isEncrypted else {
            runPlainPack(
                sources: sources,
                target: target,
                format: defaults.format,
                level: defaults.level,
                destinationPane: destinationPane
            )
            return
        }
        host?.enqueue(
            FileOperation(
                kind: .pack(
                    PackJob(
                        sourceDirectory: panel.path,
                        names: sources.map(\.name),
                        archive: target,
                        encryption: defaults.encryption,
                        namePrivacy: defaults.namePrivacy,
                        level: defaults.level,
                        passphrase: passphrase
                    )
                ),
                sources: sources,
                destinationDirectory: destinationPane.panel.path
            ),
            conflictPolicy: .fail,
            resolveConflict: nil,
            onError: nil
        )
        showTransientStatus(
            String(
                localized: "Encrypting “\(target.lastComponent)”…",
                comment: "Status while an encrypted archive is being written; %@ is its name."
            )
        )
    }

    /// Spawn `bsdtar` off-main to create the archive, then re-list the destination pane with the
    /// new archive selected. On failure the partial file is already cleaned up by `ArchivePacker`.
    private func runPlainPack(
        sources: [FileEntry],
        target: VFSPath,
        format: ArchivePacking.Format,
        level: ArchivePacking.CompressionLevel,
        destinationPane: PanelViewController
    ) {
        let sourceNames = sources.map(\.name)
        let sourceDirectory = panel.path.path
        let archivePath = target.path
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ArchivePacker.pack(
                        sourceNames: sourceNames,
                        inDirectory: sourceDirectory,
                        toArchiveAt: archivePath,
                        format: format,
                        level: level
                    )
                }.value
                destinationPane.refreshCurrentDirectory(selecting: target)
            } catch {
                presentOperationFailure(
                    message: String(localized: "Couldn’t create the archive"),
                    detail: describe(error)
                )
            }
        }
    }
}
