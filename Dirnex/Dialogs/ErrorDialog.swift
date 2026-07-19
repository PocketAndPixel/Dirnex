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
        let verb = context.kind == .copy ? "copy" : "move"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t \(verb) “\(context.path.lastComponent)”"
        alert.informativeText = VFSErrorText.sentence(for: context.error)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all remaining errors"

        // Retry is the default (leftmost / return-key) so a transient hiccup is one keystroke
        // to shrug off; Abort is last, like Cancel.
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Abort")
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
