import AppKit
import DirnexCore

/// Running user scripts on the selection (PLAN.md §M6 "user actions — shell scripts receiving
/// selection as argv/env"). The pane owns only the AppKit shell: it assembles the `UserScriptContext`
/// from the marked files and the two panes' directories, resolves the shell, and hands both to the
/// tested `DirnexCore.UserScript` (which builds the secure argv) and `UserScriptRunner` (which
/// spawns it). A pick can arrive from the ⌘K palette or the right-click **Scripts ▸** submenu; both
/// carry the script's name in the sender's `representedObject`, so this one entry point serves both.
///
/// Like Open With / Share, the targets are gated on being *real local files*: a script is handed
/// filesystem paths as argv, which an archive member or an SFTP row cannot supply. A `combined`
/// script can still run with nothing selected (it acts on the current directory via the
/// environment), so the gate is "the active pane is a local folder", not "something is selected".
extension PanelViewController {
    // MARK: - Context

    /// The context a script runs in, or `nil` when there is nowhere local to run it. The selection
    /// is the marked local files (empty is allowed for a `combined` script); the working directory
    /// is the active pane's folder, and the other pane's folder is exported as `DIRNEX_OTHER_DIR`
    /// when it too is local.
    func userScriptContext() -> UserScriptContext? {
        let selection = handoffTargets().map(\.path)
        let currentDirectory: String
        if panel.path.backend == .local {
            currentDirectory = panel.path.path
        } else if let first = handoffTargets().first {
            // A virtual pane (search results) has no real cwd of its own, but its rows are real
            // local files — run from the first hit's folder so relative work still has a home.
            currentDirectory = first.deletingLastPathComponent().path
        } else {
            return nil
        }
        let other = host?.panelCounterpart(of: self)
        let otherDirectory = other.flatMap { pane -> String? in
            pane.panel.path.backend == .local ? pane.panel.path.path : nil
        }
        return UserScriptContext(
            selection: selection,
            currentDirectory: currentDirectory,
            otherDirectory: otherDirectory
        )
    }

    /// The shell a script runs under: the user's `$SHELL`, or `/bin/zsh` when it says nothing usable
    /// — the same resolution the terminal drawer uses (`TerminalShell.login`).
    private func resolveScriptShell() -> String {
        TerminalShell.login(shellPath: ProcessInfo.processInfo.environment["SHELL"]).executablePath
    }

    // MARK: - Run

    /// Run the user script named by the sender's `representedObject` (a palette pick or a Scripts ▸
    /// submenu item) against the current selection.
    @objc func runUserScript(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String,
              let script = UserScriptStore.load().script(named: name) else { return }
        runScript(script)
    }

    /// Assemble the context and launch `script`, reporting any failures when it finishes.
    func runScript(_ script: UserScript) {
        guard let context = userScriptContext() else {
            presentOperationFailure(
                message: String(
                    localized: "Can’t run “\(script.name)”",
                    comment: "Script run failure title; %@ is the script name."
                ),
                detail: String(
                    localized: "The active panel isn’t a folder on this disk.",
                    comment: "Script run failure detail: no local folder to run in."
                )
            )
            return
        }
        // A per-file transform with nothing marked has nothing to do — say so rather than launching
        // zero processes silently (a combined script, by contrast, runs against the directory).
        if script.runMode == .perFile, context.selection.isEmpty {
            presentOperationFailure(
                message: String(
                    localized: "Nothing selected",
                    comment: "Script run failure title: a per-file script needs a selection."
                ),
                detail: String(
                    localized: "“\(script.name)” runs once per file — select one or more items first.",
                    comment: "Script run failure detail; %@ is the script name."
                )
            )
            return
        }
        UserScriptRunner.run(script, context: context, shell: resolveScriptShell()) { [weak self] outcome in
            self?.reportScriptOutcome(outcome)
        }
    }

    /// Surface a script run's result. Silent on success — new files appear through the pane's
    /// FSEvents watch — and a summary alert only when something exited non-zero or failed to launch.
    private func reportScriptOutcome(_ outcome: UserScriptRunner.RunOutcome) {
        guard let first = outcome.failures.first else { return }
        let message: String
        if outcome.failures.count == 1, outcome.total == 1 {
            message = String(
                localized: "“\(outcome.script.name)” failed",
                comment: "Script outcome title, single file; %@ is the script name."
            )
        } else {
            message = String(
                localized: "“\(outcome.script.name)” failed on \(outcome.failures.count) of \(outcome.total)",
                comment: "Script outcome title; %1$@ script name, %2$lld failures of %3$lld runs."
            )
        }
        var detail = first.stderr.isEmpty
            ? (
                first.exitCode.map {
                    String(
                        localized: "Exited with status \($0).",
                        comment: "Script outcome detail; %lld is the non-zero exit status."
                    )
                } ?? String(
                    localized: "The script could not be launched.",
                    comment: "Script outcome detail: the process failed to spawn."
                )
            )
            : first.stderr
        if let file = first.files.first {
            detail = String(
                localized: "\((file as NSString).lastPathComponent): \(detail)",
                comment: "Script outcome detail prefixed by the file it failed on; %1$@ file name, %2$@ detail."
            )
        }
        presentOperationFailure(message: message, detail: detail)
    }

    // MARK: - Manage

    /// Open the scripts organizer to create, edit, reorder, or remove scripts.
    @objc func manageUserScripts(_ sender: Any?) {
        presentAsSheet(UserScriptsOrganizerController())
    }

    // MARK: - Scripts submenu

    /// The items for the right-click **Scripts ▸** submenu: one per saved script (dispatched to
    /// `runUserScript`), then a rule and **Manage Scripts…**. Built fresh each time the submenu
    /// opens (`menuNeedsUpdate`), so a script added in the organizer shows up without a relaunch.
    func scriptMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let scripts = UserScriptStore.load().scripts
        let runnable = userScriptContext() != nil
        for script in scripts {
            let item = NSMenuItem(
                title: script.name,
                action: #selector(runUserScript(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = script.name
            item.isEnabled = runnable
            items.append(item)
        }
        if scripts.isEmpty {
            let empty = NSMenuItem(
                title: String(
                    localized: "No Scripts",
                    comment: "Scripts submenu: shown when no user scripts have been created."
                ),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            items.append(empty)
        }
        items.append(.separator())
        let manage = NSMenuItem(
            title: String(
                localized: "Manage Scripts…",
                comment: "Scripts submenu item: open the scripts organizer."
            ),
            action: #selector(manageUserScripts(_:)),
            keyEquivalent: ""
        )
        manage.target = self
        items.append(manage)
        return items
    }

    // MARK: - Validation

    /// Validate the automation commands. Returns `nil` for any other selector so the main
    /// `validateMenuItem` switch handles it — split out like its siblings to keep that method under
    /// SwiftLint's cyclomatic-complexity limit.
    func validateAutomationItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(runUserScript(_:)):
            // Runnable when the active pane offers a local folder to run in, and never while a
            // rename field is up (⌃-less, but a right-click item could still fire mid-edit).
            return userScriptContext() != nil && !(view.window?.firstResponder is NSText)
        case #selector(manageUserScripts(_:)):
            return true
        default:
            return nil
        }
    }
}
