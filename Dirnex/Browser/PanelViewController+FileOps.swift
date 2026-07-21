import AppKit
import DirnexCore

/// The "instant" file operations — the ones that finish immediately and so don't need
/// the M2 progress queue: New Folder (F7) and Delete (F8 to Trash / Shift+F8 permanent).
/// Copy (F5) and Move (F6), which move bytes with progress, go through the operation
/// engine in a later pass.
///
/// Only the AppKit shell lives here (prompts, confirmation, error summaries, and the
/// post-op refresh); the byte-touching work is `DirnexCore`'s `VFSBackend` write
/// primitives, called off the main thread so a big recursive delete never blocks the UI.
extension PanelViewController {
    // MARK: - Menu / key actions (dispatched to the focused pane via the responder chain)

    @objc func newFolder(_ sender: Any?) {
        promptForNewFolder()
    }

    @objc func moveSelectionToTrash(_ sender: Any?) {
        deleteSelection(permanent: false)
    }

    @objc func deleteSelectionPermanently(_ sender: Any?) {
        deleteSelection(permanent: true)
    }

    // The ⌘Z / ⇧⌘Z actions and their validators live in `PanelViewController+Undo.swift`.

    // MARK: - FileTableViewInput (keyboard)

    func fileTableNewFolder(_ tableView: FileTableView) {
        promptForNewFolder()
    }

    func fileTableDeleteToTrash(_ tableView: FileTableView) {
        deleteSelection(permanent: false)
    }

    func fileTableDeletePermanently(_ tableView: FileTableView) {
        deleteSelection(permanent: true)
    }

    // MARK: - New Folder (F7)

    private func promptForNewFolder() {
        // `writeDirectory` is `nil` wherever there is no real directory to create into — and, for
        // the merged iCloud listing, the CloudDocs container the merge is built on (PLAN.md §M9).
        guard let target = writeDirectory else { return }
        let alert = NSAlert()
        alert.messageText = "New Folder"
        // Named for what the pane shows, not for the directory underneath: "iCloud Drive", not
        // "com~apple~CloudDocs", which is a folder the user has never heard of.
        alert.informativeText = "Create a folder in “\(panel.path.lastComponent)”."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "untitled folder"
        field.placeholderString = "Folder name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.createFolder(named: name, in: target)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
            field.selectText(nil)
        } else {
            apply(alert.runModal())
        }
    }

    private func createFolder(named name: String, in directory: VFSPath) {
        guard !name.isEmpty else { return } // an empty name is a silent cancel
        guard !name.contains("/") else {
            presentOperationFailure(
                message: "Can’t create the folder",
                detail: "Folder names can’t contain the “/” character."
            )
            return
        }

        let target = directory.appending(name)
        let backend = backend
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try backend.createDirectory(at: target)
                }.value
                refreshCurrentDirectory(selecting: target)
                focusTable()
                host?.recordUndoableAction(.newFolder(at: target))
            } catch {
                presentOperationFailure(
                    message: "Can’t create “\(name)”",
                    detail: describe(error)
                )
            }
        }
    }

    // MARK: - Delete (F8 Trash / Shift+F8 permanent)

    /// The entries an operation (delete, copy, move) targets: the marked set when
    /// anything is marked (Total Commander operates on marks over the cursor), otherwise
    /// the single cursor entry. The synthetic `..` row is never a target.
    func selectionTargets() -> [FileEntry] {
        if panel.selectionCount > 0 {
            return panel.selectedEntries
        }
        if !cursorOnParentRow, let entry = panel.currentEntry {
            return [entry]
        }
        return []
    }

    private func deleteSelection(permanent: Bool) {
        // Inside a top-level archive, F8/Shift+F8 rewrite the archive to drop the members (there's
        // no Trash to move them to) — a distinct, non-undoable path handled by `+ArchiveWrite`. A
        // nested archive is read-only (`isWritableArchive`), so it falls through to the capability
        // gate below.
        if isWritableArchive {
            beginArchiveDelete()
            return
        }
        // Degrade off the owning backend's capabilities (PLAN.md §M5): a read-only location has
        // nothing to delete; a backend without a Trash (SFTP) turns even F8 into a confirmed
        // permanent delete rather than silently failing on a missing Trash.
        let strategy = backend.capabilities(for: panel.path).deleteStrategy
        guard strategy != .unsupported else { return }
        let targets = selectionTargets()
        guard !targets.isEmpty else { return }
        let goesToTrash = !permanent && strategy == .trash
        if !goesToTrash {
            confirmPermanentDelete(of: targets) { [weak self] in
                self?.runDelete(targets, permanent: true)
            }
        } else if AppPreferences.shared.confirmTrash {
            confirmTrash(of: targets) { [weak self] in
                self?.runDelete(targets, permanent: false)
            }
        } else {
            runDelete(targets, permanent: false)
        }
    }

    /// Move-to-Trash normally skips confirmation (it's recoverable, matching Finder), but the
    /// user can opt into a prompt via Operations settings ("Ask before moving items to Trash").
    private func confirmTrash(of targets: [FileEntry], proceed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = targets.count == 1
            ? "Move “\(targets[0].name)” to the Trash?"
            : "Move \(targets.count) items to the Trash?"
        alert.informativeText = "You can restore items from the Trash later."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    /// Permanent delete is irreversible, so it always asks first (PLAN.md §M2
    /// "Shift+F8 permanent with explicit confirm"). Trash needs no prompt — it's
    /// recoverable, matching Finder.
    private func confirmPermanentDelete(of targets: [FileEntry], proceed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = targets.count == 1
            ? "Delete “\(targets[0].name)” permanently?"
            : "Delete \(targets.count) items permanently?"
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func runDelete(_ targets: [FileEntry], permanent: Bool) {
        let paths = targets.map(\.path)
        let backend = backend
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> DeleteResult in
                var failures: [OperationFailure] = []
                var restorations: [TrashRestoration] = []
                for path in paths {
                    do {
                        if permanent {
                            try backend.removeItem(at: path)
                        } else if let trashed = try backend.trashItem(at: path) {
                            // Capture where it landed so Cmd+Z can restore it from the Trash.
                            restorations.append(TrashRestoration(original: path, trashed: trashed))
                        }
                    } catch let error as VFSError {
                        failures.append(OperationFailure(path: path, error: error))
                    } catch {
                        failures.append(
                            OperationFailure(path: path, error: .io(path: path, code: 0))
                        )
                    }
                }
                return DeleteResult(failures: failures, restorations: restorations)
            }.value

            panel.clearSelection()
            refreshCurrentDirectory()
            focusTable()
            // Permanent delete is irreversible and never journaled; Trash is restorable.
            if !permanent,
               let record = UndoRecord.trash(result.restorations.map { ($0.original, $0.trashed) }) {
                host?.recordUndoableAction(record)
            }
            if !result.failures.isEmpty {
                presentDeletionFailures(result.failures, permanent: permanent)
            }
        }
    }

    private func presentDeletionFailures(_ failures: [OperationFailure], permanent: Bool) {
        let verb = permanent ? "delete" : "move to Trash"
        let message = failures.count == 1
            ? "Couldn’t \(verb) “\(failures[0].path.lastComponent)”"
            : "Couldn’t \(verb) \(failures.count) items"
        presentOperationFailure(message: message, detail: describe(failures[0].error))
    }

    // MARK: - Shared

    /// Re-list the current directory after a mutation and, when `selecting` names a fresh
    /// entry (a just-created folder), land the cursor on it. `Panel.setListing` re-anchors
    /// the cursor/marks by identity, so this survives the new entry appearing mid-list.
    /// Internal so `PanelViewController+Copy` can refresh both panes after a transfer.
    func refreshCurrentDirectory(selecting target: VFSPath? = nil) {
        // The merged Trash is virtual but not a snapshot: what changes in it is what the user just
        // did in this very pane (the only delete it offers is permanent), so it re-gathers rather
        // than going stale (PLAN.md §M8).
        if isTrashListing {
            reloadTrash()
            return
        }
        // The merged iCloud listing is the same case, and more so: its root is writable through
        // `writeDirectory`, so a New Folder or a paste lands *in* it and must show up (PLAN.md §M9).
        if isICloudListing {
            reloadICloudDrive(selecting: target)
            return
        }
        // Re-list a real directory — on disk or on a connected SFTP account (an SFTP path is
        // re-listable, so it must refresh after an upload/delete/mkdir even without FSEvents). A
        // virtual pane (search results, a browsed archive) has no directory to re-list, so a
        // both-panes refresh after a file operation leaves its snapshot untouched.
        guard panel.path.backend == .local || panel.path.backend.isSFTP else { return }
        loadToken += 1
        let token = loadToken
        let path = panel.path
        let tabIndex = activeTabIndex
        // Off-main sort (PLAN.md §M7 perf pass): re-listing a 100k directory after a mutation must
        // not re-sort on the main actor. `installSortedModel` re-applies the live filter and any
        // total that lands during the sort.
        let sort = panel.model.sort
        let showHidden = panel.model.showHidden
        let sizes = panel.model.directorySizes
        Task {
            guard let model = try? await DirectoryLoader.model(
                backend, at: path, sort: sort, showHidden: showHidden, directorySizes: sizes
            ) else { return }
            guard token == loadToken, panel.path == path, activeTabIndex == tabIndex else { return }
            reconcileCursorFromTable()
            installSortedModel(model)
            if let target, let index = panel.model.index(ofID: target) {
                panel.moveCursor(to: index)
                cursorOnParentRow = false
            }
            reloadEverything()
        }
    }

    func presentOperationFailure(message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.enableEscapeToCancel()
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// A single item's failure during a batch operation, in a `Sendable` shape so it can
/// cross back from the background delete task. Per-file retry/abort is a later M2 item;
/// for now failures are collected and summarized.
private struct OperationFailure: Sendable {
    let path: VFSPath
    let error: VFSError
}

/// One trashed item's before/after locations, captured so Cmd+Z can restore it from the
/// Trash (PLAN.md §M2 "delete-to-Trash restore").
private struct TrashRestoration: Sendable {
    let original: VFSPath
    let trashed: VFSPath
}

/// What a delete pass produced: the items it couldn't remove, and (for Trash) where the
/// removed items landed so the operation can be journaled for undo.
private struct DeleteResult: Sendable {
    let failures: [OperationFailure]
    let restorations: [TrashRestoration]
}
