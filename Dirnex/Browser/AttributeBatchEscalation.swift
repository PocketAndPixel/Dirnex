import AppKit
import DirnexCore

/// Many items' root-only attribute changes, offered and run as one administrator step (PLAN.md §M40
/// Slice 4): a multi-selection Save asks before anything is written, and a recursive run's report
/// offers the items it had to leave.
///
/// The commands, their chunking and the judgment of what landed are all `EscalatedAttributeBatch`'s,
/// in the core and tested there by running the real bodies. This file presents the dialog and drives
/// the transport, and the one rule it adds is the order: every body runs, then every item is read
/// back, whatever the shell answered — a cancelled second password dialog still leaves the first
/// body's items changed, and only the disk says which.
@MainActor
enum AttributeBatchEscalation {
    /// What a run did: the core's read-back, and what the shell said.
    struct Result {
        let outcome: EscalatedAttributeBatch.Outcome
        /// The tools' own stderr when a body failed, empty when it gave none, `nil` when none failed.
        let failure: String?
        let wasCancelled: Bool

        /// The sentence for an item the run left unchanged.
        var reason: String {
            if let failure, !failure.isEmpty { return failure }
            return String(
                localized: "The administrator command didn’t finish.",
                comment: "Attributes escalation failure body when the tool gave no message."
            )
        }
    }

    /// The dialog for `batch`. Authenticate is its first button. `title` names an undo or a redo.
    static func alert(for batch: EscalatedAttributeBatch, title: String? = nil) -> NSAlert {
        let terminalCommand = batch.terminalCommand()
        let canRun = batch.hasCommands
        return AdministratorEscalationAlert.make(
            title: title,
            body: canRun
                ? AdministratorEscalationAlert.batchBody(
                    count: batch.items.count, offersCommand: terminalCommand != nil
                )
                : AdministratorEscalationAlert.nothingToRun,
            omissions: batch.omissions,
            terminalCommand: terminalCommand,
            canRun: canRun
        )
    }

    /// Ask, over `window`, and call `onAuthenticate` only when the user pressed Authenticate….
    static func ask(
        _ batch: EscalatedAttributeBatch,
        over window: NSWindow?,
        onAuthenticate: @escaping @MainActor () -> Void
    ) {
        let alert = alert(for: batch)
        let canRun = batch.hasCommands
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard canRun, response == .alertFirstButtonReturn else { return }
            onAuthenticate()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }

    /// Run every body as root, then read every item back off the main actor.
    ///
    /// `shell` is the transport, injected so a test can run the bodies without a password.
    static func run(
        _ batch: EscalatedAttributeBatch,
        shell: @Sendable ([String]) async throws -> Void = { try await AdministratorShell.run($0) }
    ) async -> Result {
        var failure: String?
        var wasCancelled = false
        do {
            try await shell(batch.bodies())
        } catch AdministratorShell.Failure.cancelled {
            wasCancelled = true
        } catch let AdministratorShell.Failure.failed(message) {
            failure = message
        } catch {
            failure = ""
        }
        let outcome = await Task.detached { batch.outcomeOnDisk() }.value
        return Result(outcome: outcome, failure: failure, wasCancelled: wasCancelled)
    }
}
