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
    /// `..`). No-op when there's nothing to rename or the backend can't rename.
    private func beginMultiRename() {
        // The batch tool renames within the pane's directory, which a virtual pane lacks.
        guard !isVirtualDirectory else { return }
        guard backend.capabilities.contains(.rename) else { return }
        let targets = selectionTargets()
        guard !targets.isEmpty else { return }

        // Every name currently in the directory (unfiltered, hidden included) — the set the
        // planner checks new names against so a rename never clobbers a bystander.
        let existingNames = Set(panel.model.listing.entries.map(\.name))
        let controller = MultiRenameController(items: targets, existingNames: existingNames)
        controller.onApply = { [weak self] proposals in
            self?.applyMultiRename(proposals)
        }
        presentAsSheet(controller)
    }

    // MARK: - Apply

    /// Perform the batch off the main thread, then refresh the pane and journal the whole thing
    /// as one undo record. The planner guarantees each target is unique and lands on no existing
    /// bystander, so a plain `moveItem` per item is safe and order-independent.
    private func applyMultiRename(_ proposals: [RenameProposal]) {
        let directory = panel.path
        let jobs: [(from: VFSPath, to: VFSPath)] = proposals.compactMap { proposal in
            guard proposal.willRename else { return nil }
            return (from: proposal.source, to: directory.appending(proposal.newName))
        }
        guard !jobs.isEmpty else { focusTable(); return }

        let backend = backend
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> MultiRenameResult in
                var renamed: [(original: VFSPath, renamed: VFSPath)] = []
                var failures: [VFSPath] = []
                for job in jobs {
                    do {
                        try backend.moveItem(at: job.from, to: job.to)
                        renamed.append((original: job.from, renamed: job.to))
                    } catch {
                        failures.append(job.from)
                    }
                }
                return MultiRenameResult(renamed: renamed, failures: failures)
            }.value

            panel.clearSelection()
            // Land the cursor on the first renamed item's new location.
            refreshCurrentDirectory(selecting: result.renamed.first?.renamed)
            focusTable()
            if let record = UndoRecord.multiRename(result.renamed) {
                host?.recordUndoableAction(record)
            }
            if !result.failures.isEmpty {
                presentMultiRenameFailures(result.failures)
            }
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
/// task: the items that were renamed (for the undo record) and the ones that failed.
private struct MultiRenameResult: Sendable {
    let renamed: [(original: VFSPath, renamed: VFSPath)]
    let failures: [VFSPath]
}
