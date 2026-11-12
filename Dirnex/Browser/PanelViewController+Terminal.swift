import AppKit
import DirnexCore

/// "Open in Terminal" (Go menu / palette) — the pane's half of PLAN.md §M6's "open in
/// iTerm/Terminal/WezTerm as alternative", the escape hatch from the ⌃` drawer for people who want
/// their own terminal.
///
/// The pane owns this rather than the window because the answer is "*this* pane's directory": the
/// two panes are usually somewhere different, and the one you're looking at is the one you mean.
extension PanelViewController {
    /// Whether this pane is somewhere a terminal can be opened. A local folder is, and so is a
    /// connected SFTP folder, by way of an `ssh` session (PLAN.md §M38 Slice 3). An archive's
    /// innards and a results tab are not: a results tab's entries carry real paths, but the *tab*
    /// is a query, not a place.
    var canOpenInTerminal: Bool {
        guard ExternalTerminalLauncher.preferredTerminal() != nil else { return false }
        let location = panel.path.backend
        if location == .local { return true }
        return location.isSFTP && (backend as? CompositeBackend)?.sftpBackend(for: location) != nil
    }

    // MARK: - Menu / palette action (dispatched to the focused pane via the responder chain)

    @objc func openInTerminal(_ sender: Any?) {
        guard canOpenInTerminal else { return }
        if panel.path.backend.isSFTP {
            openSSHSession()
            return
        }
        let directoryPath = panel.path.path
        ExternalTerminalLauncher.open(directoryPath: directoryPath) { [weak self] result in
            guard let self, case let .failure(failure) = result else { return }
            presentTerminalLaunchFailure(failure)
        }
    }

    /// Ask whether the account can run a command at all before opening a window on it. Without
    /// this, an account limited to file transfer gets a terminal that opens and closes on one line
    /// of the server's prose.
    private func openSSHSession() {
        // The first answer can take a second, and a second press in it would open two windows.
        guard !isAskingAccountIdentity, let composite = backend as? CompositeBackend,
              let account = panel.path.backend.sftpLocation else { return }
        isAskingAccountIdentity = true
        let path = panel.path
        Task { [weak self] in
            let plan = await BlockingWork.run { () -> SSHSessionPlan? in
                guard let found = composite.terminalSession(at: path) else { return nil }
                let identity = try? composite.accountIdentity(at: path, isCancelled: { false })
                return SSHSessionPlan(
                    session: found.session,
                    secret: found.secret,
                    canRunCommands: identity != nil
                )
            }
            guard let self else { return }
            isAskingAccountIdentity = false
            guard let plan else { return }
            guard plan.canRunCommands else {
                presentNoShell(for: account)
                return
            }
            ExternalTerminalLauncher.open(session: plan.session, secret: plan.secret) { [weak self] result in
                guard let self, case let .failure(failure) = result else { return }
                presentTerminalLaunchFailure(failure)
            }
        }
    }

    /// What ``openSSHSession()`` learned off the main thread.
    private struct SSHSessionPlan: Sendable {
        let session: SSHTerminalSession
        let secret: String?
        let canRunCommands: Bool
    }

    /// The refusal for an account with no shell, by name. It covers a server that could not be
    /// asked as well, since `accountIdentity(at:isCancelled:)` answers `nil` for both.
    static func noShellAlert(for account: SFTPLocation) -> NSAlert {
        let alert = NSAlert()
        let name = "\(account.username)@\(account.host)"
        alert.messageText = String(
            localized: "Can’t open a terminal on \(name)",
            comment: "Open in Terminal refusal title; %@ is the SFTP account, as user@host."
        )
        alert.informativeText = String(
            localized: """
            A terminal session takes a command on the server, and this account didn’t run one. An \
            account limited to file transfer can’t run any.
            """,
            comment: "Open in Terminal refusal body: the SFTP account has no shell."
        )
        alert.alertStyle = .warning
        alert.addButton(
            withTitle: String(localized: "OK", comment: "Button that dismisses an alert.")
        )
        alert.enableEscapeToCancel()
        return alert
    }

    private func presentNoShell(for account: SFTPLocation) {
        let alert = Self.noShellAlert(for: account)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
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
