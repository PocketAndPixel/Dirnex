import AppKit
import DirnexCore

/// Synchronize Directories (PLAN.md §M5) — compare the two panes' folders and reconcile them.
/// The pane owns only the AppKit shell: it gathers the two directories, presents the
/// `SyncDirectoriesController` diff sheet, and — on commit — turns the checked decisions into
/// real work. Copies run through the window's shared `FileOperationQueue` (so a big mirror runs
/// in the background with progress, pause, and undo, exactly like F5); deletes go to the Trash
/// (recoverable and undoable). All comparison logic lives in the tested `DirnexCore.DirectorySync`.
///
/// The physical left pane is always the "left" side and the right pane the "right", regardless of
/// which one is focused, so the direction controls match the on-screen layout.
extension PanelViewController {
    // MARK: - Menu / palette action (dispatched to the focused pane via the responder chain)

    @objc func synchronizeDirectories(_ sender: Any?) {
        guard let window = host as? BrowserWindowController else { return }
        beginSync(left: window.leftPanel, right: window.rightPanel)
    }

    private func beginSync(left: PanelViewController, right: PanelViewController) {
        guard Self.canSync(left), Self.canSync(right) else {
            presentOperationFailure(
                message: String(
                    localized: "Can’t synchronize",
                    comment: "Sync failure title: a panel isn't a real local folder."
                ),
                detail: String(
                    localized: "Both panels must show a real folder on disk.",
                    comment: "Sync failure detail: both panels must be local folders."
                )
            )
            return
        }
        let leftDir = left.panel.path
        let rightDir = right.panel.path
        guard leftDir != rightDir else {
            presentOperationFailure(
                message: String(
                    localized: "The panels show the same folder",
                    comment: "Sync failure title: both panels show the same folder."
                ),
                detail: String(
                    localized: "Open a different folder in one panel to compare them.",
                    comment: "Sync failure detail: open a different folder to compare."
                )
            )
            return
        }

        let controller = SyncDirectoriesController(
            leftDir: leftDir,
            rightDir: rightDir,
            backend: backend
        )
        controller.onApply = { [weak self] decisions in
            self?.confirmAndApplySync(decisions, leftDir: leftDir, rightDir: rightDir)
        }
        controller.onCompare = { [weak self] left, right in
            self?.launchExternalDiff(comparing: left, with: right)
        }
        presentAsSheet(controller)
    }

    /// A pane can take part in a sync when it shows a real, readable on-disk folder — never a
    /// virtual search-results or archive listing.
    static func canSync(_ pane: PanelViewController) -> Bool {
        pane.panel.path.backend == .local && pane.backend.capabilities.contains(.read)
    }

    /// Whether Synchronize Directories should be enabled: two real local folders, and not the
    /// same one (nothing to reconcile against itself).
    var canSynchronize: Bool {
        guard let window = host as? BrowserWindowController else { return false }
        return Self.canSync(window.leftPanel)
            && Self.canSync(window.rightPanel)
            && window.leftPanel.panel.path != window.rightPanel.panel.path
    }

    // MARK: - Apply

    /// Confirm any deletions (a mirror can remove files), then run the checked decisions.
    private func confirmAndApplySync(
        _ decisions: [SyncDirectoriesController.Decision],
        leftDir: VFSPath,
        rightDir: VFSPath
    ) {
        let deletions = decisions.filter { $0.action == .deleteLeft || $0.action == .deleteRight }.count
        guard deletions > 0 else {
            applySync(decisions, leftDir: leftDir, rightDir: rightDir)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Synchronizing will move \(deletions) items to the Trash.",
            comment: "Sync delete confirmation title; %lld is the number of items. Plural."
        )
        alert.informativeText = String(
            localized: "You can restore them from the Trash later.",
            comment: "Sync delete confirmation body."
        )
        alert.addButton(withTitle: String(
            localized: "Synchronize",
            comment: "Confirm button of the sync delete prompt and the sync sheet."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.applySync(decisions, leftDir: leftDir, rightDir: rightDir)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    private func applySync(
        _ decisions: [SyncDirectoriesController.Decision],
        leftDir: VFSPath,
        rightDir: VFSPath
    ) {
        // Batch copies by destination directory so each folder is one queue job (multiple
        // sources → one FileOperation), and collect delete paths for a single Trash pass.
        var copyGroups: [VFSPath: [FileEntry]] = [:]
        var deletePaths: [VFSPath] = []
        for decision in decisions {
            switch decision.action {
            case .copyToRight:
                if let source = decision.entry.left {
                    let dest = destinationDirectory(
                        root: rightDir,
                        relativePath: decision.entry.relativePath
                    )
                    copyGroups[dest, default: []].append(source)
                }
            case .copyToLeft:
                if let source = decision.entry.right {
                    let dest = destinationDirectory(
                        root: leftDir,
                        relativePath: decision.entry.relativePath
                    )
                    copyGroups[dest, default: []].append(source)
                }
            case .deleteRight:
                if let entry = decision.entry.right { deletePaths.append(entry.path) }
            case .deleteLeft:
                if let entry = decision.entry.left { deletePaths.append(entry.path) }
            case .none, .conflict:
                break
            }
        }
        for (destination, sources) in copyGroups {
            submitSyncCopy(sources: sources, destination: destination)
        }
        if !deletePaths.isEmpty { runSyncDeletes(deletePaths) }
    }

    /// The directory a copy of the item at `relativePath` lands in, under `root`. The relative
    /// path's parent always exists on the destination side — the comparison only descends into
    /// directories present on *both* sides, so a differing item's parent is already there.
    private func destinationDirectory(root: VFSPath, relativePath: String) -> VFSPath {
        let parents = relativePath.split(separator: "/").dropLast()
        return parents.reduce(root) { $0.appending(String($1)) }
    }

    /// Enqueue one copy job under the `.overwrite` policy — the user already decided in the diff,
    /// so newer/changed items replace their counterpart without a per-file prompt (the atomic
    /// temp-swap keeps the original until the copy completes). Failures still surface via
    /// `ErrorPrompter`; the window journals the transfer for undo as the job finishes.
    private func submitSyncCopy(sources: [FileEntry], destination: VFSPath) {
        let errorPrompter = ErrorPrompter(window: view.window)
        let operation = FileOperation(
            kind: .copy,
            sources: sources,
            destinationDirectory: destination
        )
        host?.enqueue(
            operation,
            conflictPolicy: .overwrite,
            resolveConflict: nil,
            onError: { errorPrompter.resolve($0) }
        )
    }

    /// Move the sync's delete targets to the Trash off the main thread, journal them as one undo
    /// record, and re-list both panes. Trash (not permanent delete) keeps a mirror recoverable.
    private func runSyncDeletes(_ paths: [VFSPath]) {
        let backend = backend
        Task {
            let restorations = await Task.detached(priority: .userInitiated) { () -> [
                (VFSPath, VFSPath)
            ] in
                var out: [(VFSPath, VFSPath)] = []
                for path in paths {
                    if let trashed = try? backend.trashItem(at: path) {
                        out.append((path, trashed))
                    }
                }
                return out
            }.value
            if let record = UndoRecord.trash(restorations) {
                host?.recordUndoableAction(record)
            }
            if let window = host as? BrowserWindowController {
                window.leftPanel.refreshCurrentDirectory()
                window.rightPanel.refreshCurrentDirectory()
            }
        }
    }
}
