import AppKit
import DirnexCore

/// Deleting members from inside a browsed archive (F8, PLAN.md §M4 "Archive writes: add/delete
/// inside zip"). Unlike a local delete this can't go to the Trash — the archive is rewritten whole
/// (`ArchiveWriter`, extract → drop members → repack → atomic swap) — so it always confirms first.
/// On success the pane drops the archive's stale mount and re-lists the current inner directory in
/// place.
///
/// **It is undoable, and the sheet says which it will be before it runs** (HISTORY.md ▸ After M19,
/// 2026-09-01). The rewrite keeps a copy
/// of the container as it was (`ArchiveUndoStorage`), so ⌘Z swaps it back and ⇧⌘Z swaps the rewrite
/// back in; an archive larger than the whole budget keeps the permanent wording it always had. The
/// question is asked of the archive's size, so the answer is stable — see
/// ``ArchiveUndoBudget/admits(archiveOfSize:)`` for why the store's current contents are not
/// consulted.
extension PanelViewController {
    /// Delete the marked members (or the cursor member) from the archive being browsed. A no-op off
    /// an archive pane or with nothing selected. F8 and Shift+F8 both land here — there's no Trash
    /// inside an archive, so both mean the same permanent rewrite.
    func beginArchiveDelete() {
        guard let archivePath = panel.path.backend.archivePath else { return }
        let targets = selectionTargets()
        guard !targets.isEmpty else { return }
        confirmArchiveDelete(of: targets, inArchiveAt: archivePath) { [weak self] in
            self?.runArchiveDelete(targets, inArchiveAt: archivePath)
        }
    }

    private func confirmArchiveDelete(
        of targets: [FileEntry],
        inArchiveAt archivePath: String,
        proceed: @escaping () -> Void
    ) {
        let archiveName = (archivePath as NSString).lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = targets.count == 1
            ? String(localized: "Delete “\(targets[0].name)” from “\(archiveName)”?")
            : String(localized: "Delete \(targets.count) items from “\(archiveName)”?")
        alert.informativeText = ArchiveUndoStorage.willBeUndoable(archiveAt: archivePath)
            ? String(
                localized: "This rewrites the archive. Undo puts it back.",
                comment: """
                Body of the delete-from-archive confirmation when the rewrite will be undoable — \
                Dirnex keeps a copy of the archive as it was.
                """
            )
            : String(
                localized: "This rewrites the archive and can’t be undone.",
                comment: """
                Body of the delete-from-archive confirmation when the archive is too large for \
                Dirnex to keep a copy of, so the rewrite cannot be reversed.
                """
            )
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.enableEscapeToCancel()

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func runArchiveDelete(_ targets: [FileEntry], inArchiveAt archivePath: String) {
        let innerPaths = targets.map(\.path.path)
        let name = (archivePath as NSString).lastPathComponent
        let encoding = declaredNameEncoding(forArchiveAt: archivePath)
        // An encrypted archive is rewritten through libarchive and needs the passphrase — asked for
        // once per archive per session by the shared funnel, which also owns the retry on a typo.
        withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
            try await BlockingWork.run {
                Result {
                    try ArchiveWriter.delete(
                        innerPaths: innerPaths,
                        fromArchiveAt: archivePath,
                        passphrase: passphrase,
                        undo: ArchiveUndoStorage.request(),
                        nameEncoding: encoding
                    )
                }
            }.get()
        } onSuccess: { [weak self] snapshot in
            guard let self else { return }
            // The mounted TOC is now stale — drop it so the re-list re-reads the rewritten archive.
            (backend as? CompositeBackend)?.invalidateMountedArchive(at: archivePath)
            journalArchiveRewrite(snapshot)
            panel.clearSelection()
            refreshArchiveDirectory()
            focusTable()
        } onFailure: { [weak self] error in
            guard let self else { return }
            // A legacy archive refuses before anything has been altered, and the answer is a code
            // page rather than an error message — so offer the chooser instead of reporting.
            guard !offerNameEncoding(after: error, forArchiveAt: archivePath) else { return }
            presentOperationFailure(
                message: targets.count == 1
                    ? String(localized: "Couldn’t delete “\(targets[0].name)”")
                    : String(localized: "Couldn’t delete \(targets.count) items from “\(name)”"),
                detail: describe(error)
            )
        }
    }

    /// Journal a finished archive rewrite so ⌘Z can swap the container back.
    ///
    /// One funnel for all three gestures that rewrite an archive — F8 delete, ⌘V/F5/F6 add, and an
    /// edited member saved back — because what each of them produced is the same thing: one new
    /// container, with one copy of the old one beside it. `nil` is the ordinary "not undoable"
    /// answer (an archive over the budget, or a store that could not be written) and is silent,
    /// because the gesture's own confirmation already said so before it ran.
    ///
    /// The record is built here rather than at capture time because half of it describes what the
    /// rewrite *produced*, which only exists once the swap has landed
    /// (``ArchiveUndoSnapshot/record(date:)``).
    func journalArchiveRewrite(_ snapshot: ArchiveUndoSnapshot?) {
        guard let record = snapshot?.record() else { return }
        host?.recordUndoableAction(record)
    }

    /// Re-list the current archive inner directory after a rewrite, re-anchoring the cursor by
    /// identity (`Panel.setListing`). The local-only `refreshCurrentDirectory` skips virtual panes,
    /// so an archive pane needs its own re-list; it mirrors that method but touches no history and
    /// re-reads through the (just-invalidated) mount. If the current directory itself was removed —
    /// the whole archive emptied so its inner folder is gone — it falls back to the archive root.
    func refreshArchiveDirectory() {
        guard isArchive else { return }
        loadToken += 1
        let token = loadToken
        let path = panel.path
        let tabIndex = activeTabIndex
        let backend = backend
        Task {
            let listing = try? await DirectoryLoader.list(backend, at: path)
            guard token == loadToken, panel.path == path, activeTabIndex == tabIndex else { return }
            guard let listing else {
                // The inner directory no longer exists in the rewritten archive — retreat to root.
                navigate(to: VFSPath(backend: path.backend, path: "/"), recordHistory: false)
                return
            }
            reconcileCursorFromTable()
            panel.setListing(listing)
            cursorOnParentRow = panel.isEmpty && parentRowCount > 0
            reloadEverything()
        }
    }
}
