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
extension MultiAttributesController {
    @objc func saveAttributes(_ sender: Any?) {
        let patch = buildPatch()
        guard !patch.isEmpty else { dismiss(sender); return }

        // Pre-flight the whole selection: if *any* item's change needs root, refuse the batch before
        // touching a single file and name the item, rather than half-applying and hitting the bare
        // EPERM this whole design exists to avoid. `canEdit` already ruled out foreign ownership, so
        // the reachable case is narrow — a system-immutable item among the set.
        for item in items {
            let diff = patch.diff(against: item.attributes)
            let reasons = AttributePrivilege.reasons(
                for: diff, current: item.attributes, actor: actor
            )
            if let reason = reasons.first {
                presentNeedsAdministrator(reason, name: item.entry.name)
                return
            }
        }

        var entries: [UndoRecord.AttributeBatchEntry] = []
        var failures: [(name: String, error: Error)] = []
        for item in items {
            let diff = patch.diff(against: item.attributes)
            guard !diff.isEmpty else { continue } // this item already matched the patch
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
                failures.append((item.entry.name, error))
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

    // MARK: - Alerts

    private func presentNeedsAdministrator(_ reason: AttributePrivilege.Reason, name: String) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "This change needs an administrator",
            comment: "Attributes save alert title: the change requires root privileges."
        )
        alert.informativeText = AttributeFormatting.privilegeExplanation(reason, name: name)
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        present(alert, dismissAfter: false)
    }

    private func presentFailures(_ failures: [(name: String, error: Error)], dismissAfter: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Some items couldn’t be changed",
            comment: "Multi-selection attributes failure title."
        )
        // Name the first failure in full; the OS error is the same one the single-item path shows.
        alert.informativeText = String(
            localized: "“\(failures[0].name)”: \(VFSErrorText.sentence(for: failures[0].error))",
            comment: "Multi-selection failure detail; %1$@ is an item name, %2$@ the reason."
        )
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
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
