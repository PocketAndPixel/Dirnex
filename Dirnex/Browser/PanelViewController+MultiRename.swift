import AppKit
import DirnexCore

/// The Multi-Rename Tool (⇧F2) — TC's batch rename over the marked set (PLAN.md §M4). Unlike
/// inline rename (F2), which edits one name in place, this opens a sheet where a `RenameSpec`
/// drives a live preview of every item's new name; committing applies them all as one undoable
/// batch.
///
/// The pane owns only the AppKit shell: it gathers the targets, presents `MultiRenameController`,
/// and — on commit — performs the moves off the main thread through the `VFSBackend` primitive
/// and records a single `UndoRecord.multiRename` so Cmd+Z reverses the whole batch. All planning
/// (token substitution, collision detection) lives in the tested `DirnexCore.MultiRename`.
extension PanelViewController {
    // MARK: - Menu / key action (dispatched to the focused pane via the responder chain)

    @objc func multiRenameSelection(_ sender: Any?) {
        beginMultiRename()
    }

    /// Open the tool on the operation targets (the marked set, else the cursor entry — never
    /// `..`). No-op when there's nothing to rename or this pane can't rename.
    ///
    /// Internal rather than private so `RenameReachTests` can drive the real refusal; the whole
    /// point of the fix it pins is that this guard and the menu item's are one property.
    func beginMultiRename() {
        // `canRenameHere`, the same property ⇧F2's menu item grays itself off — see `beginRename`.
        guard canRenameHere else { return }
        let targets = selectionTargets()
        guard !targets.isEmpty else { return }

        // The names already in each directory the marked items live in (unfiltered, hidden
        // included) — the set the planner checks new names against so a rename never clobbers a
        // bystander. In a tree the selection can span levels, so this is one set per folder rather
        // than one shared set: a rename in a child is checked against that child, not the root.
        let controller = MultiRenameController(
            items: targets,
            existingNamesByDirectory: existingNamesByDirectory(for: targets)
        )
        controller.onApply = { [weak self] proposals in
            self?.applyMultiRename(proposals, targets: targets)
        }
        presentAsMovableWindow(controller)
    }

    /// The existing names in every directory the marked items live in, keyed by directory. In list
    /// mode that is one entry (`panel.path`); in a tree it is each distinct parent among the marks,
    /// read from the tree's own per-level listing so a child's bystanders are the child's names.
    private func existingNamesByDirectory(for targets: [FileEntry]) -> [VFSPath: Set<String>] {
        let directories = Set(targets.compactMap { $0.path.parent })
        var result: [VFSPath: Set<String>] = [:]
        for directory in directories {
            if let entries = panel.tree?.entries(in: directory) {
                result[directory] = Set(entries.map(\.name))
            } else if directory == panel.path {
                result[directory] = Set(panel.model.listing.entries.map(\.name))
            }
        }
        return result
    }

    // MARK: - Apply

    /// Perform the batch off the main thread, then refresh the pane and journal the whole thing
    /// as one undo record. The planner guarantees each target is unique and lands on no existing
    /// bystander, so a plain `moveItem` per item is safe and order-independent.
    ///
    /// `targets` is what the tool was opened on, carried through so an item the backend refuses to
    /// rename in place (`EXDEV` — an S3 prefix) can be handed to the queue as the `FileEntry` the
    /// pane already had, rather than re-`stat`ed over the network for a value nobody discarded.
    private func applyMultiRename(_ proposals: [RenameProposal], targets: [FileEntry]) {
        // Each item is renamed in its *own* directory, not the pane's. A tree selection spans
        // levels, so the destination has to come from each source's parent — `panel.path` (the
        // tree root) would rename in place *and* move every child item up to the root, the same
        // second-index-space trap inline rename hit (docs/NOTES.md).
        let jobs: [(from: VFSPath, to: VFSPath)] = proposals.compactMap { proposal in
            guard proposal.willRename else { return nil }
            let directory = proposal.source.parent ?? panel.path
            return (from: proposal.source, to: directory.appending(proposal.newName))
        }
        guard !jobs.isEmpty else { focusTable(); return }

        let entriesByPath = Dictionary(
            targets.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let backend = backend
        Task {
            let result = await BlockingWork.run { () -> MultiRenameResult in
                var renamed: [(original: VFSPath, renamed: VFSPath)] = []
                var deferred: [(from: VFSPath, to: VFSPath)] = []
                var failures: [VFSPath] = []
                for job in jobs {
                    do {
                        try backend.moveItem(at: job.from, to: job.to)
                        renamed.append((original: job.from, renamed: job.to))
                    } catch {
                        // `EXDEV` is the backend asking for the long way round rather than a
                        // refusal, so it is collected apart and offered to the queue below — the
                        // same reading `PanelViewController+Rename` gives it for one item.
                        if RenameDeferral.isDeferred(error) {
                            deferred.append(job)
                        } else {
                            failures.append(job.from)
                        }
                    }
                }
                return MultiRenameResult(renamed: renamed, deferred: deferred, failures: failures)
            }

            panel.clearSelection()
            // Land the cursor on the first renamed item's new location.
            refreshCurrentDirectory(selecting: result.renamed.first?.renamed)
            focusTable()
            if let record = UndoRecord.multiRename(result.renamed) {
                host?.recordUndoableAction(record)
            }
            // The failures report waits for the confirmation to close: a second sheet raised on a
            // window that already has one is queued invisibly (docs/NOTES.md ▸ AppKit).
            let failures = result.failures
            queueDeferredRenames(
                result.deferred.compactMap { job in
                    entriesByPath[job.from].map {
                        DeferredRename(source: $0, newName: job.to.lastComponent)
                    }
                },
                then: { [weak self] in
                    if !failures.isEmpty { self?.presentMultiRenameFailures(failures) }
                }
            )
        }
    }

    private func presentMultiRenameFailures(_ failures: [VFSPath]) {
        let message = failures.count == 1
            ? String(localized: "Couldn’t rename “\(failures[0].lastComponent)”")
            : String(localized: "Couldn’t rename \(failures.count) items")
        presentOperationFailure(
            message: message,
            detail: String(localized: "The other items were renamed.")
        )
    }
}

/// What a batch rename produced, in a `Sendable` shape so it can cross back from the background
/// task: the items that were renamed (for the undo record), the ones the backend can only rename
/// through the queue, and the ones that failed for real.
private struct MultiRenameResult: Sendable {
    let renamed: [(original: VFSPath, renamed: VFSPath)]
    let deferred: [(from: VFSPath, to: VFSPath)]
    let failures: [VFSPath]
}
