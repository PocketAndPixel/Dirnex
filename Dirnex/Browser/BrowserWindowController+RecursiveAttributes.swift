import DirnexCore

/// Where a finished recursive attributes apply reaches the user (PLAN.md §M14 Slice 4).
///
/// On the *window*, not the pane, for the reason the checksum report is: the job outlives the sheet
/// that started it. The user can change tabs, switch panes or start another operation while a
/// hundred-thousand-item tree is walked, and the answer must still arrive — once, over whatever is on
/// screen then.
///
/// This is also where the undo record is built, and that is the part worth being careful about. The
/// material does **not** come from `OperationReport.outcomes` — a job that moves nothing produces
/// none — it comes from ``AttributeApplyOutcome/changed``, which
/// `UndoRecord.attributeBatchChange(_:)` turns into one record spanning the whole tree.
/// `UndoRecord.transfer` deliberately returns `nil` for this kind so there is exactly one place that
/// can get it right or wrong.
extension BrowserWindowController {
    /// Journal and report a finished attributes job. Called from `finalizeCompletedJobs` for every
    /// terminal job; any other kind has `nil` here and falls straight through.
    func presentAttributeApplyOutcome(of report: OperationReport, kind: FileOperation.Kind) {
        guard case .attributes = kind, let outcome = report.attributeApply else { return }

        // Journal before reporting, so ⌘Z is live by the time the user has read the sentence. A
        // cancelled run still journals what it managed to change — there is no half-written file to
        // clean up here, only work done and work not done.
        if let record = UndoRecord.attributeBatchChange(outcome.changed) {
            recordUndoableAction(record)
        }
        presentSummary(outcome, report: report)
    }

    /// What happened, in one sentence, in the status line — unless something needs the user to stop.
    ///
    /// The split follows the checksum precedent: a result the user can see for themselves (the pane
    /// has re-listed; the permissions are right there) does not deserve a modal, while a claim they
    /// would otherwise never learn does. Two things qualify. **Items that could not be changed** —
    /// a foreign-owned file inside the tree is collected and carried past rather than aborting the
    /// run, so the only place it can surface is here. And a run **too large to undo**, which was
    /// agreed to before it started and is worth confirming afterwards, since ⌘Z will now reverse
    /// some *older* action instead.
    private func presentSummary(_ outcome: AttributeApplyOutcome, report: OperationReport) {
        guard report.failures.isEmpty else {
            presentPartialSummary(outcome, report: report)
            return
        }
        let changed = outcome.changedCount
        if !outcome.isUndoable, changed > 0 {
            presentIssues(
                title: String(
                    localized: "Changed \(changed) items",
                    comment: "Recursive apply summary title; %lld is how many changed. Plural."
                ),
                lines: [String(
                    localized: """
                    That was too many to undo, so ⌘Z will reverse whatever you did before this \
                    instead.
                    """,
                    comment: "Recursive apply note when the run exceeded the undo journal's limit."
                )]
            )
            return
        }
        focusedPanel.showTransientStatus(
            report.wasCancelled
                ? String(
                    localized: "Stopped after changing \(changed) items",
                    comment: "Status after a canceled recursive apply; %lld is the count. Plural."
                )
                : String(
                    localized: "Changed \(changed) items",
                    comment: "Status after a recursive apply; %lld is how many changed. Plural."
                )
        )
    }

    /// Some items could not be changed. Names the first and counts the rest, the shape every other
    /// per-item failure summary in the app uses — a modal storm over a tree walk is the one thing
    /// this must not become.
    private func presentPartialSummary(_ outcome: AttributeApplyOutcome, report: OperationReport) {
        let failed = report.failures.count
        var lines = [String(
            localized: "\(failed) items couldn’t be changed: \(describe(report.failures[0]))",
            comment: "Recursive apply failure line; %1$lld is the count, %2$@ the first reason."
        )]
        if !outcome.isUndoable, outcome.changedCount > 0 {
            lines.append(String(
                localized: "The rest was too much to undo, so this can’t be reversed.",
                comment: "Recursive apply note when a partly-failed run also exceeded the limit."
            ))
        }
        presentIssues(
            title: String(
                localized: "Changed \(outcome.changedCount) items, with issues",
                comment: "Recursive apply partial-failure title; %lld is how many changed. Plural."
            ),
            lines: lines
        )
    }

    private func describe(_ failure: OperationItemFailure) -> String {
        leftPanel.describe(failure.error)
    }
}
