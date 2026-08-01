import AppKit
import DirnexCore

/// The sheet that stands between "Save" and a change that reaches into a whole tree (PLAN.md §M14
/// Slice 4).
///
/// It exists to say two things before anything is touched, and the second is the one that cannot
/// wait until afterwards:
///
/// - **How many items this is about to change.** Counted with the run's own walk
///   (``AttributeApplyRunner/count(sources:target:using:isCancelled:)``), so the number the user
///   agrees to is the number that runs — a count derived any other way would be a second definition
///   of "what is in scope", free to drift from the one that applies.
/// - **Whether it can be undone.** An undo step encodes to a dead-constant 246 bytes and the journal
///   is re-encoded on every later operation, so past ``AttributeApplyJob/journalLimit`` the run
///   journals nothing at all. That is a fact about the operation the user is authorising, not a
///   detail to discover when ⌘Z does nothing.
///
/// The count is a real directory walk, so it runs off the main thread; on this machine a 5 000-entry
/// directory listed in 16 ms, which puts a hundred thousand items around a third of a second.
@MainActor
enum RecursiveApplyConfirmation {
    /// Count `sources` and their contents, then ask. `proceed` runs only on an explicit confirmation.
    static func ask(
        over sources: [FileEntry],
        job: AttributeApplyJob,
        using backend: any VFSBackend,
        in window: NSWindow?,
        proceed: @escaping (AttributeApplyJob) -> Void
    ) {
        let target = job.target
        Task { @MainActor in
            let count = await Task.detached(priority: .userInitiated) {
                AttributeApplyRunner.count(sources: sources, target: target, using: backend)
            }.value
            present(count: count, job: job, in: window, proceed: proceed)
        }
    }

    private static func present(
        count: Int,
        job: AttributeApplyJob,
        in window: NSWindow?,
        proceed: @escaping (AttributeApplyJob) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Change \(count) items?",
            comment: "Recursive apply confirmation title; %lld is how many items will change. Plural."
        )
        alert.informativeText = count > job.journalLimit
            ? String(
                localized: """
                This is more than Undo can hold, so it can’t be reversed. Permissions inside \
                folders are easy to change and hard to remember, so check the scope before going \
                ahead.
                """,
                comment: "Recursive apply confirmation body when the run is too large to undo."
            )
            : String(
                localized: """
                Everything inside is changed too, not just the items you selected. One Undo puts \
                it all back.
                """,
                comment: "Recursive apply confirmation body for a run that can be undone."
            )
        alert.addButton(withTitle: String(
            localized: "Apply",
            comment: "Confirm button of the recursive-apply sheet."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel()

        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            proceed(job)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }
}
