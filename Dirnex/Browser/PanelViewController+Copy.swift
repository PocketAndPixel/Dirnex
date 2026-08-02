import AppKit
import DirnexCore

/// Copy (F5) and Move (F6) — the byte-moving operations, run through the window's shared
/// `FileOperationQueue` so large transfers run in the background while browsing continues
/// (PLAN.md §M2). Total Commander semantics: the operation targets the marked set over the
/// cursor and lands in the *other* pane's current directory.
///
/// This file owns only the AppKit shell — resolving the source set and destination, then
/// handing the operation to the queue under the `.ask` conflict policy with a
/// `ConflictPrompter` that raises the rich per-file dialog on collisions. Progress (the
/// window's queue bar), the per-file conflict dialogs, and the post-op re-list of both panes
/// all happen as the queued job runs; the byte work lives in the tested engine.
extension PanelViewController {
    // MARK: - Menu actions (dispatched to the focused pane via the responder chain)

    @objc func copyToOtherPane(_ sender: Any?) {
        // F5 inside an archive is copy-*out*: extract the marked members to disk and copy them
        // into the other pane (PLAN.md §M4). A move-out doesn't exist — the archive is read-only,
        // so there's nothing to remove — hence only Copy routes here; `moveToOtherPane` stays gated.
        if isArchive {
            beginArchiveExtraction()
        } else if let destPane = archiveDestinationPane() {
            // F5 into an archive is add-into: copy the marked local items into the archive pane.
            addSelectionToArchive(destPane, kind: .copy)
        } else {
            beginTransfer(kind: .copy)
        }
    }

    @objc func moveToOtherPane(_ sender: Any?) {
        // F6 into an archive is add-into with move semantics: copy the items in, then trash the
        // originals. Move-*out* of an archive stays gated (`moveToOtherPane` requires `!isArchive`).
        if let destPane = archiveDestinationPane() {
            addSelectionToArchive(destPane, kind: .move)
        } else {
            beginTransfer(kind: .move)
        }
    }

    /// The other pane when it's an archive ready to receive an add — the F5/F6 add-into target.
    /// `nil` (the normal transfer path) unless this pane holds real local files and the counterpart
    /// is a *writable* archive; a nested archive is read-only (`isWritableArchive`), so it isn't a
    /// target and F5/F6 fall through to `beginTransfer`, which reports it can't copy there.
    private func archiveDestinationPane() -> PanelViewController? {
        guard !isArchive, let destPane = host?.panelCounterpart(of: self),
              destPane.isWritableArchive else { return nil }
        return destPane
    }

    /// Hand this pane's marked/cursor items to the archive pane as an add, consuming the marks the
    /// moment the operation is queued (matching the local F5/F6 flow). For a copy the marks are
    /// cleared here; for a move the source rows stay until `removeArchiveMoveOriginals` trashes them.
    private func addSelectionToArchive(_ destPane: PanelViewController, kind: FileOperation.Kind) {
        let sources = selectionTargets()
        guard !sources.isEmpty else { return }
        destPane.beginArchiveAdd(localSources: sources, kind: kind, from: self)
        if kind == .copy {
            panel.clearSelection()
            reloadEverything()
            focusTable()
        }
    }

    // MARK: - Flow

    private func beginTransfer(kind: FileOperation.Kind) {
        // F5/F6 reach here via the key model, which bypasses menu validation — so re-check that
        // this isn't an archive pane, whose entries can't be extracted yet (a later M4 pass).
        guard !isArchive else { return }
        let sources = recursiveTargets()
        guard !sources.isEmpty, let destPane = host?.panelCounterpart(of: self) else { return }
        let destination = destPane.panel.path
        // The queue writes into a real directory — on disk (`.local`), or on a connected SFTP or
        // FTP account (an upload through that backend's transfer primitive). A read-only nested
        // archive or a search-results pane has no directory to receive files; a *writable* archive
        // was already routed to add-into before reaching here.
        guard destination.backend == .local
            || destination.backend.isSFTP
            || destination.backend.isFTP else {
            presentOperationFailure(
                message: transferFailureTitle(kind),
                detail: String(
                    localized: "The other panel isn’t a folder you can copy into.",
                    comment: "Copy/move failure detail: destination isn't a writable folder."
                )
            )
            return
        }
        // Copying/moving a selection onto the folder it already lives in would collide
        // with every item; point the user at a real destination instead.
        guard destination != panel.path else {
            presentOperationFailure(
                message: kind == .copy
                    ? String(
                        localized: "Can’t copy into the same folder",
                        comment: "Copy failure title: source and destination are the same folder."
                    )
                    : String(
                        localized: "Can’t move into the same folder",
                        comment: "Move failure title: source and destination are the same folder."
                    ),
                detail: String(
                    localized: "Open a different folder in the other panel first.",
                    comment: "Copy/move failure detail: pick a different destination."
                )
            )
            return
        }
        // In tree mode the marked set can span levels, and TC's branch-view semantics are to
        // reproduce each item's path *relative to this pane's directory* under the destination
        // (PLAN.md §M15) — so the transfer becomes one job per destination subdirectory. A
        // selection that sits entirely at this pane's own level is a single group with no relative
        // path, which is every list-mode transfer and takes the shipped single-job path unchanged.
        let groups = TreeSelection.transferGroups(sources, relativeTo: panel.path)
        if groups.count == 1, groups[0].relativeComponents.isEmpty {
            submitTransfer(kind: kind, sources: sources, destination: destination)
            consumeTransferMarks()
        } else {
            submitBranchTransfer(kind: kind, groups: groups, destination: destination)
        }
    }

    /// Marks are consumed the moment the operation is queued, matching the delete flow; the source
    /// rows themselves stay until the job runs and the window controller re-lists both panes on
    /// completion.
    private func consumeTransferMarks() {
        panel.clearSelection()
        reloadEverything()
        focusTable()
    }

    /// A transfer whose sources span several tree levels: recreate the folders they came from under
    /// the destination, then hand each directory's sources to the queue as its own job.
    ///
    /// The alternative — everything flat into one folder — collides silently the moment two expanded
    /// folders each hold an `x.jpg`, which is why the semantics were settled before the slice opened.
    ///
    /// The directories must exist before the jobs run (the engine writes into
    /// `destinationDirectory`, it does not create it), so they are made first, off the main thread,
    /// walking each group's chain from the destination down — `alreadyExists` is the ordinary answer
    /// for a folder the destination already has, not a failure. The marks are consumed only once
    /// that succeeds, so a failure here leaves the selection intact to retry. Each group then goes
    /// through `submitTransfer`, so the conflict prompter, the error prompter and the undo
    /// journalling are the flat path's, unchanged.
    private func submitBranchTransfer(
        kind: FileOperation.Kind,
        groups: [TreeTransferGroup],
        destination: VFSPath
    ) {
        let backend = backend
        let directories = intermediateDirectories(for: groups, under: destination)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    for directory in directories {
                        do {
                            try backend.createDirectory(at: directory)
                        } catch VFSError.alreadyExists {
                            continue
                        }
                    }
                }.value
            } catch {
                presentOperationFailure(
                    message: transferFailureTitle(kind),
                    detail: describe(error)
                )
                return
            }
            for group in groups {
                submitTransfer(
                    kind: kind,
                    sources: group.sources,
                    destination: group.destination(under: destination)
                )
            }
            consumeTransferMarks()
        }
    }

    /// Every directory a branch transfer has to make under `destination`, each after the ones that
    /// contain it: the full chain of every group's relative path, de-duplicated, since a group's own
    /// parent need not itself be a group (marking one file three levels down is one group and three
    /// directories).
    private func intermediateDirectories(
        for groups: [TreeTransferGroup],
        under destination: VFSPath
    ) -> [VFSPath] {
        var directories: [VFSPath] = []
        var seen: Set<VFSPath> = []
        for group in groups {
            var current = destination
            for component in group.relativeComponents {
                current = current.appending(component)
                if seen.insert(current).inserted { directories.append(current) }
            }
        }
        return directories
    }

    /// The alert title for a copy/move that can't proceed — one definition, so the two strings are
    /// looked up (and translated) once however many sites raise them.
    private func transferFailureTitle(_ kind: FileOperation.Kind) -> String {
        kind == .copy
            ? String(
                localized: "Can’t copy here",
                comment: "Copy failure title: destination can't receive files."
            )
            : String(
                localized: "Can’t move here",
                comment: "Move failure title: destination can't receive files."
            )
    }

    /// Hand a copy/move to the window's shared queue under the `.ask` conflict policy: the
    /// engine copies non-colliding items straight through and, for each collision, calls back
    /// into a fresh `ConflictPrompter` that raises the rich per-file dialog (and remembers an
    /// "apply to all" choice for the rest of this operation). A sibling `ErrorPrompter` fields
    /// per-file *failures* the same way — TC's Skip / Retry / Abort. Shared by F5/F6 (destination
    /// = the other pane) and drag-drop (`PanelViewController+Drop`, destination = the drop target).
    func submitTransfer(
        kind: FileOperation.Kind,
        sources: [FileEntry],
        destination: VFSPath
    ) {
        let conflictPrompter = ConflictPrompter(window: view.window)
        let errorPrompter = ErrorPrompter(window: view.window)
        let operation = FileOperation(
            kind: kind,
            sources: sources,
            destinationDirectory: destination
        )
        host?.enqueue(
            operation,
            conflictPolicy: .ask,
            resolveConflict: { context in
                // A source landing exactly on itself — Cmd+C then Cmd+V into its own folder —
                // is a duplicate, not a collision: rename it "<name> copy" without a prompt,
                // matching Finder. This only arises for a copy paste; F5/F6 target the other
                // pane and drop rejects a same-folder drop, so neither reaches this branch, and
                // a same-folder *move* is filtered out before it is ever enqueued.
                if context.source.path == context.existing.path { return .keepBoth }
                return conflictPrompter.resolve(context)
            },
            onError: { errorPrompter.resolve($0) }
        )
    }
}
