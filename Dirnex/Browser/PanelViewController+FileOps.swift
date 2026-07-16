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
        guard !isVirtualDirectory else { return } // no real directory to create into here
        let alert = NSAlert()
        alert.messageText = "New Folder"
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
            self?.createFolder(named: name)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
            field.selectText(nil)
        } else {
            apply(alert.runModal())
        }
    }

    private func createFolder(named name: String) {
        guard !name.isEmpty else { return } // an empty name is a silent cancel
        guard !name.contains("/") else {
            presentOperationFailure(
                message: "Can’t create the folder",
                detail: "Folder names can’t contain the “/” character."
            )
            return
        }

        let target = panel.path.appending(name)
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
        // Re-list a real directory — on disk or on a connected SFTP account (an SFTP path is
        // re-listable, so it must refresh after an upload/delete/mkdir even without FSEvents). A
        // virtual pane (search results, a browsed archive) has no directory to re-list, so a
        // both-panes refresh after a file operation leaves its snapshot untouched.
        guard panel.path.backend == .local || panel.path.backend.isSFTP else { return }
        loadToken += 1
        let token = loadToken
        let path = panel.path
        let tabIndex = activeTabIndex
        Task {
            guard let listing = try? await DirectoryLoader.list(backend, at: path) else { return }
            guard token == loadToken, panel.path == path, activeTabIndex == tabIndex else { return }
            reconcileCursorFromTable()
            panel.setListing(listing)
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

// MARK: - Menu validation

extension PanelViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Boolean view toggles (checkmark items) and the directory-mutating ops are validated in
        // their own helpers so this switch stays under the cyclomatic-complexity limit.
        if let toggle = validateToggleItem(menuItem) { return toggle }
        if let mutating = validateMutatingItem(menuItem) { return mutating }
        if let archive = validateArchiveItem(menuItem) { return archive }
        if let navigation = validateNavigationItem(menuItem) { return navigation }
        if let handoff = validateHandoffItem(menuItem) { return handoff }
        if let automation = validateAutomationItem(menuItem) { return automation }
        switch menuItem.action {
        case #selector(copyToOtherPane(_:)):
            // Copy to the other pane works from a results panel (real paths) and from an archive,
            // where F5 becomes copy-*out* — extract the marked members to the other pane. Both
            // just need a counterpart to land in; the extraction path re-checks it's local.
            return !selectionTargets().isEmpty && host?.panelCounterpart(of: self) != nil
        case #selector(moveToOtherPane(_:)):
            // Move can't come out of a read-only archive (there's nothing to remove); a results
            // panel still allows it (each target carries its real on-disk path).
            return !isArchive && !selectionTargets().isEmpty && host?.panelCounterpart(of: self) != nil
        case #selector(copy(_:)):
            // `copy:` only reaches the pane when the file table is first responder — a name/
            // path field editor intercepts ⌘C for text copy — so this validates the file case.
            // An archive entry has no on-disk URL to place on the pasteboard, and a remote SFTP
            // entry has no *local* one (F5 copies it out instead), so both are excluded.
            return !isArchive && !panel.path.backend.isSFTP && !selectionTargets().isEmpty
        case #selector(saveCurrentSearch(_:)):
            // Only meaningful on a results pane that still carries the query behind it.
            return canSaveCurrentSearch
        case #selector(showTagsMenu(_:)):
            // Only local files carry tags. Gated on the *targets*, not the pane, so tagging works
            // from a results tab (virtual pane, real local hits) — and, like ⌃D, ⌃T must reach a
            // field editor rather than being stolen to open a popup while a name is being typed.
            return canEditTags && !(view.window?.firstResponder is NSText)
        case #selector(undoLastOperation(_:)):
            return validateUndoItem(menuItem)
        case #selector(redoLastOperation(_:)):
            return validateRedoItem(menuItem)
        default:
            return true
        }
    }

    /// Validate the Go menu's items. Returns `nil` for any other selector so the main switch
    /// handles it. Split out for the same reason as its siblings below: `validateMenuItem` has to
    /// stay under SwiftLint's cyclomatic-complexity limit (a recurring gotcha).
    private func validateNavigationItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(goToParentDirectory(_:)):
            // "Go Up" walks out of an archive too, but is meaningless at a backend root or on a
            // virtual search-results pane.
            return isArchive || (panel.path.backend == .local && panel.parentPath != nil)
        case #selector(goBack(_:)):
            return tabs[activeTabIndex].history.canGoBack
        case #selector(goForward(_:)):
            return tabs[activeTabIndex].history.canGoForward
        case #selector(showHistory(_:)):
            // Like ⌃D, let ⌥↓ reach a field editor while a name/path field is being edited
            // instead of stealing it to open the history popup.
            return !(view.window?.firstResponder is NSText)
        case #selector(showHotlist(_:)):
            // While a name/path field is being edited, let ⌃D fall through to the field
            // editor's delete-forward instead of stealing it to open the hotlist.
            return !(view.window?.firstResponder is NSText)
        case #selector(openInTerminal(_:)):
            // Needs a real directory on disk (never an archive, an SFTP server, or a results tab)
            // and a terminal to open it in — Terminal.app ships with macOS, so in practice this
            // only turns on the first half.
            return canOpenInTerminal
        default:
            return nil
        }
    }

    /// Validate the directory-mutating operations — the ones that need a real, writable
    /// directory and so are all disabled on a virtual search-results pane (`isSearchResults`).
    /// Returns `nil` for any other selector so the main switch handles it. Split out to keep
    /// `validateMenuItem` under SwiftLint's cyclomatic-complexity limit (a recurring gotcha).
    private func validateMutatingItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(newFolder(_:)):
            return canWriteHere
        case #selector(moveSelectionToTrash(_:)), #selector(deleteSelectionPermanently(_:)):
            // Inside a top-level archive, delete rewrites it to drop the members (no Trash, not
            // undoable) — enabled on a non-empty selection. Elsewhere the owning backend must be
            // able to delete at all: a search-results pane and a read-only nested archive report
            // `.read`, whose `deleteStrategy` is `.unsupported`, so both stay disabled.
            if isWritableArchive { return !selectionTargets().isEmpty }
            return backend.capabilities(for: panel.path).deleteStrategy != .unsupported
                && !selectionTargets().isEmpty
        case #selector(paste(_:)):
            // ⌘V pastes into a real writable folder, or *adds into* a writable browsed archive
            // (PLAN.md §M4 — a nested archive is read-only, so it's excluded).
            return (canWriteHere || isWritableArchive) && clipboardHasFiles()
        case #selector(pasteAndMoveFromClipboard(_:)):
            // ⌥⌘V has no standard selector, so it reaches the pane even mid text-edit — step it
            // aside for a field editor, else gate it like Paste.
            return canWriteHere && clipboardHasFiles() && !(view.window?.firstResponder is NSText)
        case #selector(renameSelection(_:)):
            // Rename is single-item on the cursor (not the marked set) and never `..`.
            return canRenameHere && !cursorOnParentRow && panel.currentEntry != nil
        case #selector(multiRenameSelection(_:)):
            // The batch tool operates on the marked set (else the cursor entry).
            return canRenameHere && !selectionTargets().isEmpty
        case #selector(synchronizeDirectories(_:)):
            // Compares the two panes' folders — needs two distinct real local directories.
            return canSynchronize
        case #selector(compareByContents(_:)):
            // Diffs the two panes' cursor files — needs a real file under each cursor.
            return canCompareByContents
        default:
            return nil
        }
    }

    /// Validate the archive operations (Pack). Kept out of the main switch so it stays under
    /// SwiftLint's cyclomatic-complexity limit (a recurring gotcha). Returns `nil` for any other
    /// selector so the main switch handles it.
    private func validateArchiveItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(packSelection(_:)):
            // Pack a real local selection into a new archive in the other pane; the source must be
            // a real folder (not an archive or search-results view) and there must be a pane to
            // land the archive in. The pack flow re-checks the destination is local + writable.
            return canPackFromHere && !selectionTargets().isEmpty && host?.panelCounterpart(of: self) != nil
        default:
            return nil
        }
    }

    /// This pane can create/paste into its directory — driven off the *owning* backend's
    /// capabilities (PLAN.md §M5): a virtual pane (search results or a browsed archive) reports
    /// `.read`, so `.write` is absent and the op greys out; a real disk (and a future writable
    /// SFTP mount) reports `.write`.
    private var canWriteHere: Bool {
        backend.capabilities(for: panel.path).contains(.write)
    }

    /// This pane can rename an item in place — the owning backend advertises `.rename`.
    private var canRenameHere: Bool {
        backend.capabilities(for: panel.path).contains(.rename)
    }

    /// Boolean view toggles that carry a checkmark tracking their state and are always
    /// enabled (the standard macOS convention). Returns `nil` for any other selector so the
    /// main enable/disable switch handles it.
    private func validateToggleItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(toggleShowHidden(_:)):
            // "Show Hidden Files" checkmark tracks the app-wide state.
            menuItem.state = AppPreferences.shared.showHidden ? .on : .off
            return true
        case #selector(toggleShowTags(_:)):
            // "Show Tags" checkmark tracks the app-wide state — the preference itself, not
            // `isTagColumnVisible`: inside an archive the column is suppressed because there are no
            // tags to show there, and unchecking the box would blame the user's setting for it.
            menuItem.state = AppPreferences.shared.showTags ? .on : .off
            return true
        case #selector(toggleSizeVisualization(_:)):
            // Tracks the tab's own flag rather than `areSizeBarsVisible`, for the reason above: on
            // an SFTP volume or in search results the bars are suppressed because there is nothing
            // sane to walk, and that is not the user having switched the mode off.
            menuItem.state = isSizeVisualizationEnabled ? .on : .off
            // Disabled where it cannot apply, so the greying explains the suppression that the
            // checkmark alone would leave looking like a bug.
            return panel.path.backend == .local && !isSearchResults
        case #selector(toggleQuickViewPanel(_:)):
            // "Quick View Panel" checkmark tracks the window-wide Quick View state.
            menuItem.state = (host?.isQuickViewEnabled ?? false) ? .on : .off
            return true
        default:
            return nil
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
