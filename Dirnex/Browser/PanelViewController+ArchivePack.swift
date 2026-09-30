import AppKit
import DirnexCore

/// Pack (Alt+F5) — TC's "create an archive from the selected files" (PLAN.md §M4 "pack via
/// F5-with-archive-target"), the inverse of F5 copy-out from inside an archive.
///
/// Packing isn't a cross-backend copy through `CopyEngine`; it writes one archive file directly.
/// The marked/cursor items of this pane are packed into the *other* pane's folder — the same default
/// destination as F5. A small sheet picks the base name, container format and, for a zip, a
/// passphrase; the new archive lands selected in the other pane, immediately browsable (its suffix is
/// one `ArchiveType.isBrowsable` recognizes).
///
/// **Neither end has to be on this Mac** (PLAN.md §M24 Slice 6). The sources are brought down first
/// through `PanelViewController+Materialize`, and each then names its **own** directory
/// (``DirnexCore/PackSource``), because a staged set is one directory per file and a tree can mark
/// rows at two depths; the destination is asked `capabilities(for:)` on its own directory, and an
/// archive bound for a server is built in a temp directory and transferred (``DirnexCore/PackStaging``).
/// The download happens after the sheet and after the collision question, so a user who backs out of
/// either has paid nothing.
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

    /// Whether this pane can be a pack *source* — which since M24 Slice 6 is a question about the
    /// **rows**, not about the pane.
    ///
    /// It used to read `panel.path.backend == .local && !isVirtualDirectory`, on the reasoning that
    /// `bsdtar` needs one `-C` over one real directory. Both halves of that have gone: every row is
    /// brought down to a real file before the writer sees it (`PanelViewController+Materialize`),
    /// and `PackSource` lets each one name its own directory, so a set that is not one folder's
    /// worth — a staged download, a browsed archive's members, marks at two depths of a tree —
    /// packs like any other. What is left is the only thing that was ever load-bearing: there has
    /// to be something to pack.
    var canPackFromHere: Bool {
        !selectionTargets().isEmpty
    }

    /// Validate the marked/cursor items, resolve the destination (the other pane), and raise the
    /// pack sheet. Re-checks `canPackFromHere` since Alt+F5 can arrive via the key model.
    func beginArchivePacking() {
        guard canPackFromHere else { return }
        let sources = selectionTargets()
        guard !sources.isEmpty, let destPane = host?.panelCounterpart(of: self) else { return }
        guard destinationAcceptsArchive(destPane) else { return }

        let defaults = PackAccessory.Defaults(
            baseName: ArchivePacking.defaultBaseName(
                forSourceNames: sources.map(\.name),
                sourceDirectoryName: panel.path.lastComponent
            )
        )
        presentPackSheet(sources: sources, destinationPane: destPane, defaults: defaults)
    }

    /// Whether the other pane can receive the finished archive, reporting if it cannot.
    ///
    /// **The question is about the destination directory, not about this Mac** (M24 Slice 6). An
    /// archive bound for a server is built in a temp directory and transferred, which is what makes
    /// `capabilities(for:)` the right question asked of the right path: a writable bucket or SFTP
    /// folder says yes, a browsed archive says no because `ArchiveBackend` advertises `.read` alone,
    /// and a read-only bucket says no in advance rather than after the whole archive was written.
    ///
    /// `capabilities(for:)` rather than the backend-wide `capabilities`, which on a routing
    /// `CompositeBackend` is always the *local* backend's — one question, two spellings, and the
    /// compiler checks neither (docs/NOTES.md ▸ Design lessons).
    private func destinationAcceptsArchive(_ destination: PanelViewController) -> Bool {
        let directory = destination.panel.path
        if !destination.isVirtualDirectory,
           destination.backend.capabilities(for: directory).contains(.write) {
            return true
        }
        presentOperationFailure(
            message: String(localized: "Can’t pack here"),
            detail: String(
                localized: """
                Open a folder that can be written to in the other panel to hold the new archive.
                """,
                comment: "Pack failure detail when the other panel cannot receive an archive."
            )
        )
        return false
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
        alert.enableEscapeToCancel()

        let accessory = PackAccessory.make(defaults)
        alert.accessoryView = accessory.view
        alert.window.initialFirstResponder = accessory.nameField
        // Choosing a cipher grows the accessory and choosing None shrinks it again; an `NSAlert`
        // takes the height from that frame, so it has to be told to re-fit around it (measured:
        // `layout()` does this synchronously on a live sheet — docs/NOTES.md). Weak because the
        // completion handler below already owns `accessory`, and `alert` owns the accessory's view.
        accessory.onHeightChange = { [weak alert] in alert?.layout() }

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
        let request = PackRequest(
            sources: sources,
            target: destinationPane.panel.path.appending(archiveName),
            defaults: defaults,
            passphrase: passphrase,
            destinationPane: destinationPane
        )
        let target = request.target
        let run: () -> Void = { [weak self] in self?.runPack(request) }
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
        alert.enableEscapeToCancel()
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

    /// Bring the sources down to real files and then send the pack down whichever of the two paths
    /// its cipher chose.
    ///
    /// **The download happens here**, after the sheet and after the collision question — so a user
    /// who backs out of either has paid nothing, and the one confirmation naming the total arrives
    /// when the pack is otherwise settled. A set that is already on this disk reaches the writer
    /// synchronously with no dialog and no job, which is every ordinary ⌥F5.
    ///
    /// **A marked cloud placeholder is fetched, like a compare's and a checksum's**, because the
    /// engine behind this refuses to read through one rather than discovering it mid-walk — which is
    /// M24's structural rule, and is what `EncryptedArchiveError.wouldDownloadPlaceholder`'s own
    /// comment has said since it shipped ("a file the user pointed at may be downloaded on request,
    /// but packing a *folder* is a tree sweep"). It is never *weighed*: `CloudDownloadPrompt` names
    /// the file and its size and carries a Stop, so a confirmation in front of it would be a second
    /// thing reporting one transfer. A placeholder the walk **discovers** inside a marked folder is
    /// in no plan and still meets the engine's refusal, which is the half of that rule M14 wrote.
    private func runPack(_ request: PackRequest) {
        materialize(request.sources, for: .pack, includingPlaceholders: true) {
            String(
                localized: "Couldn’t create the archive",
                comment: "Alert title when the files to be packed can't be downloaded or extracted."
            )
        } then: { [weak self] urls in
            self?.runPack(PanelViewController.packSources(for: urls), for: request)
        }
    }

    /// Where each staged file is and what it is called, derived from the URL itself.
    ///
    /// **Both halves come from the same URL** rather than one from the URL and the name from the
    /// row, so they cannot disagree about a file that is provably there: `MaterializeRunner` keeps a
    /// downloaded object's real name inside its own directory and `ArchivePreviewCache` keeps an
    /// extracted member's, but a *row's* name is not always a file name — the merged iCloud listing
    /// draws an app's name over its `Documents` folder, which is the one row in this codebase where
    /// the two differ.
    ///
    /// This is also what fixes ⌥F5 in a **tree**, which has been wrong since trees shipped: the
    /// pack was handed `panel.path` plus bare names, so a marked row inside an expanded folder named
    /// a file that is not in the pane's own directory — `bsdtar` failed, and the encrypted walk
    /// skipped the missing name and wrote a smaller archive without saying so.
    static func packSources(for urls: [URL]) -> [PackSource] {
        urls.map {
            PackSource(directory: $0.deletingLastPathComponent().path, name: $0.lastPathComponent)
        }
    }

    private func runPack(_ packing: [PackSource], for request: PackRequest) {
        let defaults = request.defaults
        let target = request.target
        guard let passphrase = request.passphrase, defaults.encryption.isEncrypted else {
            runPlainPack(packing, for: request)
            return
        }
        host?.enqueue(
            FileOperation(
                kind: .pack(
                    PackJob(
                        sources: packing,
                        archive: target,
                        encryption: defaults.encryption,
                        namePrivacy: defaults.namePrivacy,
                        level: defaults.level,
                        passphrase: passphrase
                    )
                ),
                sources: request.sources,
                destinationDirectory: request.destinationPane.panel.path
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

    /// Queue the `bsdtar` pack, exactly as the encrypted path queues its own writer.
    ///
    /// **This was a spawn on this thread until 2026-08-30**, with no job, no bar and no Stop — so a
    /// pack bound for a server reported its upload through the status line while encrypting the same
    /// archive put both halves on the queue. The split was never about the work (both are minutes of
    /// reading and then a transfer); it was about the passphrase, which is why libarchive is linked
    /// at all. What the queue needed to take a `bsdtar` job was a way to see inside one, and there
    /// is one: the tool answers **SIGINFO** with the bytes it has read (``DirnexCore/BsdtarProgress``).
    ///
    /// The status line stays, because it says the thing a bar cannot — *which* archive — and it is
    /// what a user watching the pane rather than the queue reads.
    private func runPlainPack(_ packing: [PackSource], for request: PackRequest) {
        let target = request.target
        host?.enqueue(
            FileOperation(
                kind: .plainPack(
                    PlainPackJob(
                        sources: packing,
                        archive: target,
                        format: request.defaults.format,
                        level: request.defaults.level
                    )
                ),
                sources: request.sources,
                destinationDirectory: request.destinationPane.panel.path
            ),
            conflictPolicy: .fail,
            resolveConflict: nil,
            onError: nil
        )
        showTransientStatus(packingStatus(for: target))
    }

    /// The status line while a server-bound archive is being written on this Mac.
    private func packingStatus(for target: VFSPath) -> String {
        String(
            localized: "Packing “\(target.lastComponent)”…",
            comment: "Status while an archive bound for a server is written locally; %@ is its name."
        )
    }

    /// The status line while the finished archive is going up.
    private func sendingStatus(for target: VFSPath) -> String {
        String(
            localized: "Sending “\(target.lastComponent)”…",
            comment: "Status while a finished archive is uploaded to a server; %@ is its name."
        )
    }
}

/// Everything the pack sheet settled, carried as one value.
///
/// A struct rather than six arguments threaded through three functions, and the reason is not only
/// SwiftLint's parameter ceiling: since M24 Slice 6 the run happens *after* a download, so these
/// have to survive a round trip through a closure — and a parameter list that long is where the two
/// halves of a pack quietly stop agreeing about which pane the archive is going into.
private struct PackRequest {
    let sources: [FileEntry]
    let target: VFSPath
    let defaults: PackAccessory.Defaults
    let passphrase: ArchivePassphrase?
    let destinationPane: PanelViewController
}
