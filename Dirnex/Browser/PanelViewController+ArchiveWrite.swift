import AppKit
import DirnexCore

/// Deleting members from inside a browsed archive (F8, PLAN.md §M4 "Archive writes: add/delete
/// inside zip"). Unlike a local delete this can't go to the Trash and isn't undoable — the archive
/// is rewritten whole (`ArchiveWriter`, extract → drop members → repack → atomic swap) — so it
/// always confirms first with permanent wording. On success the pane drops the archive's stale
/// mount and re-lists the current inner directory in place.
extension PanelViewController {
    /// Delete the marked members (or the cursor member) from the archive being browsed. A no-op off
    /// an archive pane or with nothing selected. F8 and Shift+F8 both land here — there's no Trash
    /// inside an archive, so both mean the same permanent rewrite.
    func beginArchiveDelete() {
        guard let archivePath = panel.path.backend.archivePath else { return }
        let targets = selectionTargets()
        guard !targets.isEmpty else { return }
        confirmArchiveDelete(of: targets) { [weak self] in
            self?.runArchiveDelete(targets, inArchiveAt: archivePath)
        }
    }

    private func confirmArchiveDelete(of targets: [FileEntry], proceed: @escaping () -> Void) {
        let archiveName = (panel.path.backend.archivePath.map { ($0 as NSString).lastPathComponent })
            ?? String(localized: "the archive")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = targets.count == 1
            ? String(localized: "Delete “\(targets[0].name)” from “\(archiveName)”?")
            : String(localized: "Delete \(targets.count) items from “\(archiveName)”?")
        alert.informativeText = String(localized: "This rewrites the archive and can’t be undone.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))

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
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ArchiveWriter.delete(innerPaths: innerPaths, fromArchiveAt: archivePath)
                }.value
                // The mounted TOC is now stale — drop it so the re-list re-reads the rewritten archive.
                (backend as? CompositeBackend)?.invalidateMountedArchive(at: archivePath)
                panel.clearSelection()
                refreshArchiveDirectory()
                focusTable()
            } catch {
                presentOperationFailure(
                    message: targets.count == 1
                        ? String(localized: "Couldn’t delete “\(targets[0].name)”")
                        : String(localized: "Couldn’t delete \(targets.count) items from “\(name)”"),
                    detail: describe(error)
                )
            }
        }
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
