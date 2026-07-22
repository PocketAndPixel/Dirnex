import AppKit
import DirnexCore

/// Total Commander's per-file error dialog (PLAN.md §M2 "Errors: per-file skip/retry/abort"):
/// when a copy or move can't transfer one source — permission denied, disk full, a vanished
/// file — show which item failed and why, and let the user Retry it, Skip it and carry on, or
/// Abort the whole operation. An optional "apply to all" turns Skip into "skip every remaining
/// failure", so a flaky volume doesn't produce a modal storm.
///
/// Presented as a sheet on the pane's window; the engine's resolver (`ErrorPrompter`) awaits
/// the answer while its copy thread is parked — the same shape as `ConflictDialog`.
@MainActor
enum ErrorDialog {
    /// Present the dialog for one failed item and return the chosen resolution plus whether the
    /// user asked to apply it to every remaining failure in this operation.
    static func present(
        _ context: OperationErrorContext,
        in window: NSWindow?
    ) async -> (resolution: ErrorResolution, applyToAll: Bool) {
        let name = context.path.lastComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        // Two whole sentences rather than a "Couldn’t \(verb)…" with the verb inserted: many
        // languages inflect the object or reorder around the verb, which a spliced-in word can't.
        alert.messageText = context.kind == .copy
            ? String(localized: "Couldn’t copy “\(name)”")
            : String(localized: "Couldn’t move “\(name)”")
        alert.informativeText = VFSErrorText.sentence(for: context.error)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Apply to all remaining errors")

        // Retry is the default (leftmost / return-key) so a transient hiccup is one keystroke
        // to shrug off; Abort is last, like Cancel.
        alert.addButton(withTitle: String(localized: "Retry"))
        alert.addButton(withTitle: String(localized: "Skip"))
        alert.addButton(withTitle: String(localized: "Abort"))
        alert.enableEscapeToCancel() // ⎋ → Abort (there is no "Cancel" button here)

        let response = await runAlert(alert, in: window)
        let applyToAll = alert.suppressionButton?.state == .on
        return (resolution(for: response), applyToAll)
    }

    /// Show the alert as a sheet on the window, or app-modal if there is none (window closed
    /// mid-operation — a rare fallback, never the common path).
    private static func runAlert(
        _ alert: NSAlert,
        in window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private static func resolution(for response: NSApplication.ModalResponse) -> ErrorResolution {
        switch response {
        case .alertFirstButtonReturn: .retry
        case .alertSecondButtonReturn: .skip
        default: .abort // third button ("Abort") or sheet dismissal
        }
    }
}
