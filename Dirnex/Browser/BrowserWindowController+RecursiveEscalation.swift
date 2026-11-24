import AppKit
import DirnexCore

/// The administrator half of a recursive attributes change (PLAN.md §M40 Slice 4): the items the run
/// left because they need root, offered from its report and changed after one password.
///
/// On the window for the reason the report is: the run outlives the sheet that started it. The items
/// are planned again when the user asks, since the dialog can come minutes after the run, and the
/// change is **an undo step of its own** (decided with Oleg): it is a second gesture, so the first ⌘Z
/// takes back what the administrator changed and the next one the rest of the run.
extension BrowserWindowController {
    /// The partial summary with **Apply as Administrator…** beside OK. OK stays the default and the
    /// Escape button: reading a report and dismissing it must never start an escalation.
    func offerAdministrator(
        title: String,
        lines: [String],
        rootOnly: [AttributeApplyOutcome.RootOnlyItem],
        job: AttributeApplyJob
    ) {
        Self.administratorOffer(title: title, lines: lines).beginSheetIfVisible(
            over: window
        ) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.escalate(rootOnly, of: job)
        }
    }

    /// The report's alert, built apart from the window that shows it so a test can read it.
    ///
    /// OK holds the keyboard focus as well as Return and Escape. An alert opens focused on its last
    /// button and Space presses the focused one, so without that line one Space asked for the
    /// administrator password (docs/NOTES.md ▸ The keyboard in a dialog). A warning keeps the focus
    /// it is built with, however long the report.
    static func administratorOffer(title: String, lines: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.addButton(withTitle: String(
            localized: "Apply as Administrator…",
            comment: """
            Button in a recursive attributes report: change the items that need root, after the \
            administrator password.
            """
        ))
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        alert.window.initialFirstResponder = alert.buttons.first
        return alert
    }

    private func escalate(
        _ rootOnly: [AttributeApplyOutcome.RootOnlyItem],
        of job: AttributeApplyJob
    ) {
        Task { @MainActor [weak self] in
            // One `lstat` an item, off the main actor: a tree of someone else's can be every item.
            let batch = await Task.detached { EscalatedAttributeBatch(retrying: rootOnly, of: job) }.value
            guard let self else { return }
            guard !batch.items.isEmpty else {
                finishEscalation(.init(
                    outcome: batch.outcomeOnDisk(), failure: nil, wasCancelled: false
                ))
                return
            }
            AttributeBatchEscalation.ask(batch, over: window) { [weak self] in
                Task { @MainActor in
                    let result = await AttributeBatchEscalation.run(batch)
                    self?.finishEscalation(result)
                }
            }
        }
    }

    /// Journal what the administrator run left on disk, re-list, and say what happened, in the words
    /// the run's own summary uses.
    private func finishEscalation(_ result: AttributeBatchEscalation.Result) {
        let outcome = result.outcome
        // Cancelled before anything ran: a choice, with nothing to report.
        if result.wasCancelled, outcome.changedCount == 0 { return }
        if let record = UndoRecord.attributeBatchChange(outcome.changed) {
            recordUndoableAction(record)
        }
        refreshPanes()

        let changed = outcome.changedCount
        var lines: [String] = []
        if !outcome.unchanged.isEmpty {
            lines.append(String(
                localized: "\(outcome.unchanged.count) items couldn’t be changed: \(result.reason)",
                comment: "Recursive apply failure line; %1$lld is the count, %2$@ the first reason."
            ))
        }
        if !outcome.isUndoable, changed > 0 {
            lines.append(String(
                localized: """
                That was too many to undo, so ⌘Z will reverse whatever you did before this \
                instead.
                """,
                comment: "Recursive apply note when the run exceeded the undo journal's limit."
            ))
        }
        guard !lines.isEmpty else {
            focusedPanel.showTransientStatus(String(
                localized: "Changed \(changed) items",
                comment: "Status after a recursive apply; %lld is how many changed. Plural."
            ))
            return
        }
        presentIssues(
            title: outcome.unchanged.isEmpty
                ? String(
                    localized: "Changed \(changed) items",
                    comment: "Recursive apply summary title; %lld is how many changed. Plural."
                )
                : String(
                    localized: "Changed \(changed) items, with issues",
                    comment: "Recursive apply partial-failure title; %lld is how many changed. Plural."
                ),
            lines: lines
        )
    }
}
