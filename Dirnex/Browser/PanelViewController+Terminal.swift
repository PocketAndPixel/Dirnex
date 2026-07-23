import AppKit
import DirnexCore

/// "Open in Terminal" (Go menu / palette) — the pane's half of PLAN.md §M6's "open in
/// iTerm/Terminal/WezTerm as alternative", the escape hatch from the ⌃` drawer for people who want
/// their own terminal.
///
/// The pane owns this rather than the window because the answer is "*this* pane's directory": the
/// two panes are usually somewhere different, and the one you're looking at is the one you mean.
extension PanelViewController {
    /// Whether this pane has a real directory on disk a terminal could be opened at. An archive's
    /// innards, an SFTP server and a results tab are all somewhere no local shell can go — a
    /// results tab's entries carry real paths, but the *tab* is a query, not a place.
    var canOpenInTerminal: Bool {
        panel.path.backend == .local && ExternalTerminalLauncher.preferredTerminal() != nil
    }

    // MARK: - Menu / palette action (dispatched to the focused pane via the responder chain)

    @objc func openInTerminal(_ sender: Any?) {
        guard canOpenInTerminal else { return }
        let directoryPath = panel.path.path
        ExternalTerminalLauncher.open(directoryPath: directoryPath) { [weak self] result in
            guard let self, case let .failure(failure) = result else { return }
            presentTerminalLaunchFailure(failure)
        }
    }

    private func presentTerminalLaunchFailure(_ failure: ExternalTerminalLauncher.Failure) {
        guard case let .launchFailed(terminal) = failure else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Can’t open \(terminal.displayName)",
            comment: "Terminal-launch failure title; %@ is the terminal app's name."
        )
        alert.informativeText = String(
            localized: "\(terminal.displayName) is installed but couldn’t be launched.",
            comment: "Terminal-launch failure body; %@ is the terminal app's name."
        )
        alert.alertStyle = .warning
        alert.addButton(
            withTitle: String(localized: "OK", comment: "Button that dismisses an alert.")
        )
        alert.enableEscapeToCancel()
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
