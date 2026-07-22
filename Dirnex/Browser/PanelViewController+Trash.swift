import AppKit
import DirnexCore

/// The Trash, merged across volumes and shown in a virtual results tab (PLAN.md §M8 "Trash row").
///
/// macOS keeps one trash per volume — `~/.Trash` plus every mount's `.Trashes/<uid>` — and Finder
/// presents them as a single place. So does this: `SidebarLocations.trashDirectories` says which
/// ones exist, each is listed through the ordinary local backend, and the union is installed as a
/// `.trash` results tab whose entries carry their real on-disk paths. Nothing here is a new VFS
/// backend; the merge is a listing, not a filesystem.
///
/// Two behaviors make it a Trash rather than a folder view, and both fall out of existing
/// machinery rather than special cases:
///
/// - **Delete means delete.** `CompositeBackend.capabilities(for:)` grants a trash location no
///   `.trash` capability, so the M5 capability degradation already turns F8 into a confirmed
///   permanent delete. Without that, F8 here would move an item to the Trash it is already in —
///   which `FileManager` reports as a *success* while doing nothing (probed).
/// - **It re-lists after that delete**, unlike a search snapshot: what changed is what the user
///   just did in this pane, so `refreshCurrentDirectory` re-gathers the merge in place.
///
/// Reading `~/.Trash` needs Full Disk Access. Without the grant it comes back as a permission
/// error, and the pane says so through the M7 onboarding sheet instead of showing an empty Trash —
/// "there is nothing in your Trash" is a much worse answer than "I'm not allowed to look."
extension PanelViewController {
    /// Whether the active tab is showing the merged Trash.
    var isTrashListing: Bool {
        panel.path.backend == .trash
    }

    /// Open the Trash in a new virtual results tab — the sidebar's Trash row.
    func showTrash() {
        gatherTrash { [weak self] entries, sources in
            guard let self else { return }
            openResults(entries, truncated: false, as: trashPresentation())
            // The tab that just opened is the active one; watching its sources is what makes a file
            // trashed elsewhere (Finder, another app) appear here without re-clicking the row.
            watchMergedListing(sources: sources, force: true)
        }
    }

    /// Re-gather the Trash into the tab already showing it, after a delete emptied part of it.
    /// Called by `refreshCurrentDirectory`, which is the one funnel every mutation refreshes
    /// through; the cursor is re-anchored by identity by `installSortedModel`, so the row under it
    /// survives rows vanishing above it.
    func reloadTrash() {
        gatherTrash { [weak self] entries, sources in
            guard let self, isTrashListing else { return }
            // A volume mounted or unmounted since the last gather changes what there is to watch;
            // an unchanged set leaves the running stream alone.
            watchMergedListing(sources: sources)
            // The same install-then-render tail the real-directory refresh ends with.
            // `installSortedModel` only swaps the model — without `reloadEverything` the pane goes
            // on drawing the rows it had, which after an Empty Trash is a list of files that no
            // longer exist. Caught only by running it.
            _ = reconcileCursorFromTable()
            installSortedModel(resultsModel(entries, as: trashPresentation()))
            reloadEverything()
        }
    }

    // MARK: - Emptying

    /// "Empty Trash…" from the sidebar's Trash row — permanently erase every volume's trash.
    ///
    /// The confirmation names the **count**, which is what makes this safe enough to offer as a
    /// one-click menu item: emptying from the sidebar destroys items the user cannot see listed, so
    /// the sheet has to say how many there are rather than ask them to trust the word "Trash". The
    /// gather that produces the count is the same one the row browses with, so the number in the
    /// sheet is the number the pane would show.
    ///
    /// An empty Trash says so instead of opening a confirmation for nothing — the same "never a
    /// no-op the user can't read" rule the Full Disk Access menu item follows.
    func emptyTrash() {
        gatherTrash { [weak self] entries, _ in
            guard let self else { return }
            // Counted on what the Trash *shows*: a trash directory always holds a `.DS_Store` (it
            // is Finder's put-back database), so counting raw entries would offer to erase "1 item"
            // from a Trash the user sees as empty. Everything is erased, hidden files included —
            // emptying means emptying — but nothing hidden is ever counted as a reason to ask.
            let visible = entries.filter { !$0.isHidden }
            guard !visible.isEmpty else {
                presentOperationFailure(
                    message: "The Trash is empty",
                    detail: "There is nothing to erase."
                )
                return
            }
            confirmEmptyTrash(count: visible.count) { [weak self] in
                self?.runEmptyTrash(entries)
            }
        }
    }

    /// Emptying is irreversible and reaches every volume, so it always asks — and says how much is
    /// going, in the `.critical` style the permanent-delete confirmation uses.
    private func confirmEmptyTrash(count: Int, proceed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Permanently erase \(count) items from the Trash?")
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
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

    /// Remove every gathered entry, off the main thread, then re-list any pane showing the Trash.
    /// Never journaled: a permanent delete has no undo, exactly like Shift+F8.
    private func runEmptyTrash(_ entries: [FileEntry]) {
        let paths = entries.map(\.path)
        let backend = backend
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> EmptyTrashOutcome in
                var outcome = EmptyTrashOutcome()
                for path in paths {
                    do {
                        try backend.removeItem(at: path)
                    } catch {
                        // One unremovable item (a locked file, a volume gone read-only) must not
                        // abandon the rest of the Trash — collect and carry on.
                        outcome.failed.append(path)
                        outcome.firstError = outcome.firstError ?? error
                    }
                }
                return outcome
            }.value

            refreshTrashPanes()
            if let error = outcome.firstError {
                presentOperationFailure(
                    message: outcome.failed.count == 1
                        ? "Couldn’t erase “\(outcome.failed[0].lastComponent)”"
                        : "Couldn’t erase \(outcome.failed.count) items",
                    detail: describe(error)
                )
            }
        }
    }

    /// Re-list whichever panes are showing the Trash — this one and its counterpart. A pane left
    /// listing items that no longer exist is the one outcome an empty must not produce, and the
    /// merged listing has no FSEvents watcher to notice on its own.
    func refreshTrashPanes() {
        for panel in [self, host?.panelCounterpart(of: self)].compactMap({ $0 })
            where panel.isTrashListing {
            panel.refreshCurrentDirectory()
        }
    }

    /// What one empty pass produced. A local carrier because `PanelViewController+FileOps`'
    /// equivalent is `private` and Swift's `private` does not cross files (docs/NOTES.md).
    private struct EmptyTrashOutcome: Sendable {
        var failed: [VFSPath] = []
        var firstError: (any Error)?
    }

    // MARK: - Gathering

    func trashPresentation() -> ResultsPresentation {
        ResultsPresentation(
            backend: .trash,
            pathSummary: "Trash",
            sort: panel.model.sort,
            query: nil,
            scope: nil,
            title: "Trash",
            // The pane's own setting, not the results default: the dotfiles in a trash directory
            // are Finder's `.DS_Store` put-back databases, not files the user threw away.
            showsHidden: panel.model.showHidden
        )
    }

    /// List every existing trash directory off the main thread and hand back the union.
    ///
    /// A permission failure anywhere stops the flow and offers the Full Disk Access grant instead
    /// of delivering a partial answer: in practice the one directory that can be denied is
    /// `~/.Trash`, which is where all but a handful of trashed items live, so a "partial" Trash
    /// would be an empty one wearing a plausible face.
    /// Internal, not private: `PanelViewController+TrashRestore` gathers the same merge for
    /// "Restore All", and Swift's `private` does not cross files (docs/NOTES.md).
    /// The directories are handed back alongside the entries because a pane showing the merge has to
    /// *watch* them — it has no directory of its own — and they are what this pass actually read,
    /// rather than what a second enumeration would find.
    func gatherTrash(then present: @escaping ([FileEntry], [VFSPath]) -> Void) {
        let backend = backend
        let directories = SidebarLocations.trashDirectories(volumes: SidebarLocations.volumes())
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> TrashGather in
                var entries: [FileEntry] = []
                for directory in directories {
                    do {
                        entries.append(contentsOf: try backend.listDirectory(at: directory))
                    } catch let error as VFSError {
                        if case .permissionDenied = error { return .denied }
                        // A volume unmounted between the enumeration and the listing is not worth
                        // an alert — it simply has no trash to contribute any more.
                        continue
                    } catch {
                        continue
                    }
                }
                return .listed(entries)
            }.value

            switch outcome {
            case let .listed(entries): present(entries, directories)
            case .denied: FullDiskAccessOnboarding.presentForTrash(over: view.window)
            }
        }
    }

    /// What one pass over the trash directories produced: the merged entries, or the fact that the
    /// grant is missing. Deliberately not an `Error` — a denied read here is an answer to show the
    /// user, not a failure to report.
    private enum TrashGather: Sendable {
        case listed([FileEntry])
        case denied
    }
}
