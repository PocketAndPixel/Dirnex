import AppKit
import DirnexCore

/// Committing a multi-selection edit (PLAN.md §M14 Slice 4): the ``AttributePatch`` the controls
/// built, applied to each item against *its own* current attributes, with one undo record spanning
/// the batch.
///
/// Every byte-touching decision is the same tested core the single-item sheet uses — ``AttributePatch``
/// turns into a per-item ``AttributeDiff``, ``AttributePrivilege`` says whether it needs root,
/// ``AttributeChangePlan`` orders the syscalls (immutable unlock/relock and the group/mtime repairs
/// included), and ``FileAttributeIO`` runs them. This file only drives that loop and reports what
/// happened.
///
/// **Items that need root are asked for before anything is written** (PLAN.md §M40 Slice 4, decided
/// with Oleg): one administrator dialog for all of them, the single-item sheet's shape. Authenticate
/// runs theirs as root and then the user's own, and the Save is one undo record. Cancel leaves the
/// sheet as it was, with nothing changed.
extension MultiAttributesController {
    /// How a Save splits: the items this user changes directly, each with its own diff, and the ones
    /// that need root, as one batch. An item that already matches the patch is in neither.
    struct Commit {
        var own: [(item: Item, diff: AttributeDiff)] = []
        var rootOnly = EscalatedAttributeBatch(items: [])
    }

    func commit(for patch: AttributePatch) -> Commit {
        var commit = Commit()
        var rootOnly: [EscalatedAttributeBatch.Item] = []
        for item in items {
            let diff = patch.diff(against: item.attributes)
            guard !diff.isEmpty else { continue }
            if AttributePrivilege.reasons(for: diff, current: item.attributes, actor: actor).isEmpty {
                commit.own.append((item, diff))
            } else {
                rootOnly.append(.init(
                    path: item.entry.path,
                    actsOnLink: item.isSymlink,
                    current: item.attributes,
                    diff: diff
                ))
            }
        }
        commit.rootOnly = EscalatedAttributeBatch(items: rootOnly)
        return commit
    }

    @objc func saveAttributes(_ sender: Any?) {
        let patch = buildPatch()
        guard !patch.isEmpty else { dismiss(sender); return }

        // "Apply to enclosed items" replaces the flat write rather than running beside it, so the
        // marked items and everything under them are one operation with one undo record. The patch
        // needs no translation here — a bulk edit was already a patch, which is why the recursive
        // job and the flat commit can share it exactly.
        if let options = recursiveOptions, options.isRecursive {
            confirmRecursive(
                AttributeApplyJob(patch: patch, target: options.target), sender
            )
            return
        }

        let commit = commit(for: patch)
        guard !commit.rootOnly.items.isEmpty else {
            finish(commit, patch: patch, escalated: nil, sender: sender)
            return
        }
        AttributeBatchEscalation.ask(commit.rootOnly, over: view.window) { [weak self] in
            Task { @MainActor in
                let result = await AttributeBatchEscalation.run(commit.rootOnly)
                // A password dialog cancelled before anything ran is a choice, as on the single-item
                // sheet: the sheet stays, and nothing changed.
                if result.wasCancelled, result.outcome.changedCount == 0 { return }
                self?.finish(commit, patch: patch, escalated: result, sender: sender)
            }
        }
    }

    /// Write the user's own items, journal them with whatever the administrator run left on disk, and
    /// report. Only a cancel with nothing changed stops a Save before here; a run that failed is not
    /// the user's choice, so the Save goes through for their own items and the report names what the
    /// administrator run could not change, the recursive run's rule for a per-item error.
    private func finish(
        _ commit: Commit,
        patch: AttributePatch,
        escalated: AttributeBatchEscalation.Result?,
        sender: Any?
    ) {
        var entries: [UndoRecord.AttributeBatchEntry] = []
        var failures: [(name: String, reason: String)] = []
        if let escalated {
            entries.append(contentsOf: escalated.outcome.changed)
            failures += escalated.outcome.unchanged.map { ($0.lastComponent, escalated.reason) }
        }
        for (item, diff) in commit.own {
            do {
                let plan = AttributeChangePlan(
                    diff: diff, current: item.attributes, actsOnLink: item.isSymlink
                )
                try FileAttributeIO.apply(plan, to: item.entry.path)
                entries.append(.init(
                    path: item.entry.path,
                    actsOnLink: item.isSymlink,
                    old: item.attributes,
                    new: patch.apply(to: item.attributes)
                ))
            } catch {
                failures.append((item.entry.name, VFSErrorText.sentence(for: error)))
            }
        }

        // One record for the whole batch, so a single Cmd+Z reverses every item that changed.
        if let record = UndoRecord.attributeBatchChange(entries) { recordUndo?(record) }
        onApplied?()

        if failures.isEmpty {
            dismiss(sender)
        } else {
            // Anything applied is done and undoable, so close once the report is dismissed — unless
            // *nothing* applied, in which case leave the sheet open the way a single-item failure does.
            presentFailures(failures, dismissAfter: !entries.isEmpty)
        }
    }

    /// Count the tree, ask, and hand the job to the queue — the single-item sheet's path exactly,
    /// over the marked set instead of one item. There is no ACL half: bulk editing does not offer
    /// one, so there is none to propagate.
    private func confirmRecursive(_ job: AttributeApplyJob, _ sender: Any?) {
        let sources = items.map(\.entry)
        RecursiveApplyConfirmation.ask(
            over: sources,
            job: job,
            using: LocalBackend(),
            in: view.window
        ) { [weak self] confirmed in
            self?.enqueueRecursive?(confirmed, sources)
            self?.dismiss(sender)
        }
    }

    // MARK: - Alerts

    private func presentFailures(_ failures: [(name: String, reason: String)], dismissAfter: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Some items couldn’t be changed",
            comment: "Multi-selection attributes failure title."
        )
        // Name the first failure in full; the OS error is the same one the single-item path shows.
        alert.informativeText = String(
            localized: "“\(failures[0].name)”: \(failures[0].reason)",
            comment: "Multi-selection failure detail; %1$@ is an item name, %2$@ the reason."
        )
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        alert.offerFullDiskAccessSettings()
        present(alert, dismissAfter: dismissAfter)
    }

    private func present(_ alert: NSAlert, dismissAfter: Bool) {
        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] _ in
                if dismissAfter { self?.dismiss(nil) }
            }
        } else {
            alert.runModal()
            if dismissAfter { dismiss(nil) }
        }
    }
}
