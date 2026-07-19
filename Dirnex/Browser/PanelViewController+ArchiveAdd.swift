import AppKit
import DirnexCore

/// Adding local files *into* a browsed archive (paste ⌘V, F5 copy, F6 move; PLAN.md §M4 "Archive
/// writes: add/delete inside zip"), the second half of the archive-write engine and the symmetric
/// inverse of F8 delete. New items land in the archive's currently-browsed inner directory.
///
/// It reuses the same extract → edit → repack → atomic-swap rewrite as delete (`ArchiveWriter.add`,
/// which copies the items into the extracted tree). A same-named member is a *replace*, so any
/// collisions are confirmed up front before the archive is touched. Add is a copy: F6 "move" adds
/// the items and then trashes the local originals (recoverable + undoable via the standard Trash
/// journal, even though the archive rewrite itself isn't undoable).
///
/// `self` is always the *destination* archive pane. Paste enters here on the pane the ⌘V lands on;
/// F5/F6 route from the local source pane to the archive counterpart via `PanelViewController+Copy`.
extension PanelViewController {
    /// Add `localSources` (real on-disk files/folders) into this archive pane's current inner
    /// directory. `kind == .move` (F6) trashes the originals through `sourcePane` afterward; `.copy`
    /// (⌘V / F5) leaves them. A no-op off an archive pane or with nothing to add.
    func beginArchiveAdd(
        localSources: [FileEntry],
        kind: FileOperation.Kind,
        from sourcePane: PanelViewController?
    ) {
        guard isArchive, let archivePath = panel.path.backend.archivePath else { return }
        guard !localSources.isEmpty else { return }
        let destination = panel.path
        let backend = backend
        Task {
            // Gather the destination's real member names (unfiltered — a hidden member still
            // collides on disk) to warn before overwriting anything.
            let existingNames = await Task.detached(priority: .userInitiated) { () -> [String] in
                ((try? backend.listDirectory(at: destination)) ?? []).map(\.name)
            }.value
            let collisions = ArchiveMutation.collidingNames(
                addingNames: localSources.map(\.name),
                existingNames: existingNames
            )
            guard !collisions.isEmpty else {
                runArchiveAdd(
                    localSources,
                    into: destination.path,
                    archiveAt: archivePath,
                    kind: kind,
                    from: sourcePane
                )
                return
            }
            confirmArchiveReplace(names: collisions, archiveAt: archivePath) { [weak self] in
                self?.runArchiveAdd(
                    localSources,
                    into: destination.path,
                    archiveAt: archivePath,
                    kind: kind,
                    from: sourcePane
                )
            }
        }
    }

    /// ⌘V into an archive pane: stat the pasteboard's file URLs into local sources and add them.
    /// Copy only — ⌥⌘V move-paste into an archive is left out of this pass (`validateMenuItem` keeps
    /// it disabled), so there's no source set to trash.
    func pasteIntoArchive() {
        guard isArchive else { return }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: options
        ) as? [URL], !urls.isEmpty else { return }

        let backend = backend
        Task {
            let sources = await Task.detached(priority: .userInitiated) { () -> [FileEntry] in
                urls.compactMap { try? backend.stat(at: VFSPath.local($0.path)) }
            }.value
            guard !sources.isEmpty else { return }
            beginArchiveAdd(localSources: sources, kind: .copy, from: nil)
            // The paste makes this the active pane, matching the local paste/drop flows.
            host?.panelDidBecomeActive(self)
            focusTable()
        }
    }

    // MARK: - Confirm

    private func confirmArchiveReplace(
        names: [String],
        archiveAt archivePath: String,
        proceed: @escaping () -> Void
    ) {
        let archiveName = (archivePath as NSString).lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1
            ? "Replace “\(names[0])” in “\(archiveName)”?"
            : "Replace \(names.count) items in “\(archiveName)”?"
        alert.informativeText =
            "An item with the same name is already in the archive. Replacing rewrites the archive "
                + "and can’t be undone."
        alert.addButton(withTitle: "Replace")
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

    // MARK: - Run

    private func runArchiveAdd(
        _ sources: [FileEntry],
        into innerDirectory: String,
        archiveAt archivePath: String,
        kind: FileOperation.Kind,
        from sourcePane: PanelViewController?
    ) {
        let localPaths = sources.map(\.path.path)
        let name = (archivePath as NSString).lastPathComponent
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ArchiveWriter.add(
                        localPaths: localPaths,
                        toInnerDirectory: innerDirectory,
                        ofArchiveAt: archivePath
                    )
                }.value
                // The mounted TOC is now stale — drop it so the re-list re-reads the rewritten archive.
                (backend as? CompositeBackend)?.invalidateMountedArchive(at: archivePath)
                panel.clearSelection()
                refreshArchiveDirectory()
                focusTable()
                // F6 move: the archive add is a copy, so remove the originals now that it succeeded.
                if kind == .move { sourcePane?.removeArchiveMoveOriginals(sources) }
            } catch {
                presentOperationFailure(
                    message: sources.count == 1
                        ? "Couldn’t add “\(sources[0].name)”"
                        : "Couldn’t add \(sources.count) items to “\(name)”",
                    detail: describe(error)
                )
            }
        }
    }

    /// Trash the local originals of an F6 move once they've been copied into the archive — the
    /// "move" half (add-into-archive is a copy, so the sources are removed here). To the Trash, so
    /// it's recoverable, and journaled, so this half is undoable even though the rewrite isn't.
    /// Runs on the *source* pane.
    func removeArchiveMoveOriginals(_ entries: [FileEntry]) {
        let paths = entries.map(\.path)
        let backend = backend
        Task {
            let restorations = await Task.detached(priority: .userInitiated) {
                () -> [(VFSPath, VFSPath)] in
                var out: [(VFSPath, VFSPath)] = []
                for path in paths {
                    if let trashed = try? backend.trashItem(at: path) { out.append((path, trashed)) }
                }
                return out
            }.value
            panel.clearSelection()
            refreshCurrentDirectory()
            focusTable()
            if let record = UndoRecord.trash(restorations) { host?.recordUndoableAction(record) }
        }
    }
}
