import AppKit
import DirnexCore

/// Whether F5 and F6 ask and show their progress, and the queue controls the dialog is handed
/// (PLAN.md §M41).
extension BrowserWindowController {
    // MARK: - PanelHost

    func runTransfer(_ summary: TransferSummary, start: @escaping (TransferTracker) -> Void) {
        guard AppPreferences.shared.confirmTransfers,
              // A script cannot press Return, and would wait on the question for ever.
              !Scripting.isAutomating,
              transferDialog == nil,
              let window, window.attachedSheet == nil,
              let presenter = window.contentViewController
        else { return start(.untracked) }
        let queue = queue
        let dialog = TransferDialog(
            summary: summary,
            control: TransferDialog.QueueControl(
                pause: { id in Task { await queue.pause(id) } },
                resume: { id in Task { await queue.resume(id) } },
                cancel: { id in Task { await queue.cancel(id) } }
            ),
            onClose: { [weak self] in self?.transferDialog = nil }
        )
        transferDialog = dialog
        dialog.present(from: presenter, start: start)
    }
}
