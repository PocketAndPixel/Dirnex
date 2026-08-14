import AppKit
import DirnexCore

/// A rename the backend cannot perform in place, run as a queued job (PLAN.md §M21).
///
/// The case that produces it is an S3 "folder": a prefix is N objects, so `moveItem` answers
/// `EXDEV` rather than blocking on N server-side copies with no way to stop it and no way to say
/// how far it got. Before this, F2 there drew the raw errno — «The system reported an error
/// (code 18)» — and ⇧F2 quietly collected it as an unexplained failure.
///
/// `EXDEV` is already the signal `CopyEngine` turns into a recursive copy-then-delete, so nothing
/// new moves bytes here: the job carries a determinate bar, Stop, the conflict policy, per-item
/// failures and an undo record, exactly as F5/F6 do. What this file owns is the AppKit half — the
/// confirmation, because a prefix rename is N billed requests and is *not* atomic, and the handoff
/// to `submit`.
///
/// Both entry points funnel here (F2's single item and ⇧F2's batch) for the reason this milestone
/// keeps re-deriving: one rule with two spellings is one rule that will drift.
extension PanelViewController {
    /// Confirm `renames` and, if the user agrees, enqueue one job each; `then` runs once the sheet
    /// is out of the way, whichever button was pressed.
    ///
    /// `then` exists so a caller with something else to say (⇧F2's report of the items that failed
    /// for real) says it *after* this sheet closes: stacking a second sheet on a window that
    /// already has one queues it invisibly (docs/NOTES.md ▸ AppKit).
    func queueDeferredRenames(_ renames: [DeferredRename], then: (() -> Void)? = nil) {
        guard !renames.isEmpty else {
            then?()
            return
        }
        confirmDeferredRenames(renames) { [weak self] agreed in
            if agreed {
                for rename in renames { self?.submitDeferredRename(rename) }
            }
            self?.focusTable()
            then?()
        }
    }

    private func submitDeferredRename(_ rename: DeferredRename) {
        submit(renameOperation(for: rename))
    }

    /// The job one deferred rename becomes. Split out from the submit so the destination it picks
    /// is assertable without presenting the confirmation — the sheet is what makes the flow itself
    /// undrivable from a headless suite (`RenameReachTests` records what that costs).
    ///
    /// The item keeps its **own** directory: in a tree the cursor's row can live inside an expanded
    /// child, so `panel.path` is the root and rebuilding the destination from it would rename the
    /// item *and* move it up (docs/NOTES.md ▸ the second-index-space trap, which inline rename hit
    /// for real). A backend root has no parent and is never an entry, so the fallback is
    /// unreachable rather than load-bearing.
    func renameOperation(for rename: DeferredRename) -> FileOperation {
        FileOperation(
            renaming: rename.source,
            to: rename.newName,
            in: rename.source.path.parent ?? panel.path
        )
    }

    private func confirmDeferredRenames(
        _ renames: [DeferredRename],
        proceed: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        // Whole sentences per branch rather than a count spliced into one template (docs/NOTES.md).
        if renames.count == 1 {
            alert.messageText = String(
                localized: "Rename “\(renames[0].source.name)” to “\(renames[0].newName)”?",
                comment: """
                Confirmation title for a rename that has to run as a job; the two %@ are the \
                current name and the new one.
                """
            )
            alert.informativeText = String(
                localized: """
                This location can’t rename “\(renames[0].source.name)” in place, so everything \
                inside it is copied to the new name and the originals are then deleted. The job \
                runs in the background and can be stopped — stopping partway leaves some items \
                under each name.
                """,
                comment: """
                Confirmation body for a rename that has to run as a job; %@ is the current name.
                """
            )
        } else {
            alert.messageText = String(
                localized: "Rename \(renames.count) items?",
                comment: """
                Confirmation title for a batch of renames that have to run as jobs; %lld is the \
                count.
                """
            )
            alert.informativeText = String(
                localized: """
                This location can’t rename them in place, so everything inside each one is copied \
                to its new name and the originals are then deleted. The jobs run in the background \
                and can be stopped — stopping partway leaves some items under each name.
                """,
                comment: "Confirmation body for a batch of renames that have to run as jobs."
            )
        }
        alert.addButton(
            withTitle: String(
                localized: "Rename",
                comment: "Confirm button on the queued-rename confirmation."
            )
        )
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel()

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            proceed(response == .alertFirstButtonReturn)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}

/// One rename the backend refused in place: the item as the pane already knows it, and the name it
/// is to take. Built on the main actor from what is on screen rather than re-`stat`ed, since a
/// remote `stat` is a round trip and a billed request.
struct DeferredRename: Sendable {
    let source: FileEntry
    let newName: String
}

/// Whether a failed rename is one the queue can finish.
///
/// `EXDEV` from `moveItem` is a *request*, not a failure — the same signal `CopyEngine.perform` and
/// `UndoJournal.crossVolumeRestore` already read that way — so it is spelled once here and read by
/// both rename flows. Anything else is a real refusal and keeps its own alert.
enum RenameDeferral {
    static func isDeferred(_ error: any Error) -> Bool {
        guard let error = error as? VFSError, case let .io(_, code) = error else { return false }
        return code == EXDEV
    }
}
