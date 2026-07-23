import AppKit
import DirnexCore

/// The window's `PanelHost` undo surface (PLAN.md §M2 "Undo journal: Cmd+Z reverses
/// move/rename/copy/new-folder; delete-to-Trash restore; clear messaging for non-reversible
/// ops"). The panes forward their reversible operations here; Cmd+Z reverses the most recent.
/// The reversal itself lives in the tested `DirnexCore.UndoJournal`; this marshals it onto
/// the panes and surfaces anything that couldn't be put back.
extension BrowserWindowController {
    func recordUndoableAction(_ record: UndoRecord) {
        undoController.record(record)
    }

    /// A pane reports a completed marking change; journal it as a `SelectionChange` so Cmd+Z can
    /// reverse it. The window supplies the pane's `side` (which the pane itself doesn't track);
    /// `directory` names the folder the marks belong to (the pane may have already navigated away)
    /// and the post-change marks are read live off the pane's `Panel`.
    func recordSelectionChange(
        on pane: PanelViewController,
        directory: VFSPath,
        previousMarks: Set<VFSPath>,
        label: UndoActionLabel
    ) {
        let side: PaneSide = (pane === leftPanel) ? .left : .right
        undoController.recordSelection(SelectionChange(
            pane: side,
            directory: directory,
            priorSelection: previousMarks,
            newSelection: pane.panel.selection,
            label: label
        ))
    }

    var nextUndoLabel: UndoActionLabel? {
        undoController.nextLabel
    }

    var nextRedoLabel: UndoActionLabel? {
        undoController.nextRedoLabel
    }

    func undoLastOperation() {
        Task {
            switch await undoController.undo() {
            case .none:
                return
            case let .fileOperation(record, report):
                // Re-list both panes so the reversal (a restored source, a removed copy) shows at
                // once; the FSEvents watchers would catch up anyway, but this is immediate.
                leftPanel.refreshCurrentDirectory()
                rightPanel.refreshCurrentDirectory()
                presentUndoOutcome(record: record, report: report)
            case let .selection(change):
                applySelectionChange(change)
            }
        }
    }

    func redoLastOperation() {
        Task {
            switch await undoController.redo() {
            case .none:
                return
            case let .fileOperation(record, report):
                leftPanel.refreshCurrentDirectory()
                rightPanel.refreshCurrentDirectory()
                presentRedoOutcome(record: record, report: report)
            case let .selection(change):
                applySelectionChange(change)
            }
        }
    }

    /// Install a reverted selection's marks on the pane it came from. Undo and redo both land
    /// here — the journal has already picked the right set (`selectionToApply`), so this only
    /// routes to the left/right pane and lets it re-render.
    private func applySelectionChange(_ change: SelectionChange) {
        let pane = (change.pane == .left) ? leftPanel : rightPanel
        pane.applyUndoSelection(change.selectionToApply, in: change.directory)
    }

    /// Tell the user only when the undo was less than complete: a clean reversal is silent
    /// (the panes already reflect it). Non-reversible parts of the original operation and
    /// steps that couldn't be applied are both surfaced, never dropped silently.
    private func presentUndoOutcome(record: UndoRecord, report: UndoReport) {
        guard record.nonReversibleCount > 0 || !report.succeeded else { return }

        var lines: [String] = []
        if record.nonReversibleCount > 0 {
            let overwrote = record.nonReversibleCount
            lines.append(
                String(
                    localized: "\(overwrote) items overwrote existing files and can’t be restored."
                )
            )
        }
        if !report.succeeded {
            let count = report.failures.count
            let reason = leftPanel.describe(report.failures[0].error)
            lines.append(String(localized: "\(count) items couldn’t be put back: \(reason)"))
        }
        let action = LocalizedCatalog.title(for: record.label)
        presentIssues(
            title: String(
                localized: "Undo \(action) finished with issues",
                comment: "Alert title after a partial undo. %@ is the translated action name."
            ),
            lines: lines
        )
    }

    /// Redo's outcome. Unlike undo, `nonReversibleCount` is irrelevant here — redo re-applies
    /// the operation, it doesn't try to restore anything — so only the steps that couldn't be
    /// re-applied are surfaced. A clean redo is silent.
    private func presentRedoOutcome(record: UndoRecord, report: UndoReport) {
        guard !report.succeeded else { return }
        let count = report.failures.count
        let reason = leftPanel.describe(report.failures[0].error)
        let line = String(localized: "\(count) items couldn’t be re-applied: \(reason)")
        let action = LocalizedCatalog.title(for: record.label)
        presentIssues(
            title: String(
                localized: "Redo \(action) finished with issues",
                comment: "Alert title after a partial redo. %@ is the translated action name."
            ),
            lines: [line]
        )
    }

    private func presentIssues(title: String, lines: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.enableEscapeToCancel()
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
