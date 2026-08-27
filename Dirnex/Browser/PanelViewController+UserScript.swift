import AppKit
import DirnexCore

/// Running user scripts on the selection (PLAN.md §M6 "user actions — shell scripts receiving
/// selection as argv/env"). The pane owns only the AppKit shell: it assembles the `UserScriptContext`
/// from the marked files and the two panes' directories, resolves the shell, and hands both to the
/// tested `DirnexCore.UserScript` (which builds the secure argv) and `UserScriptRunner` (which
/// spawns it). A pick can arrive from the ⌘K palette or the right-click **Scripts ▸** submenu; both
/// carry the script's name in the sender's `representedObject`, so this one entry point serves both.
///
/// **The files no longer have to be on this disk** (PLAN.md §M24 Slice 5). A script is handed
/// filesystem paths as argv, which is a claim about *paths* and never about where the row lives —
/// so a marked set on a server or inside an archive is brought down first, through the same funnel
/// Open With and Share use (`PanelViewController+Materialize`), and the script is handed the copies.
/// Each copy is then watched, so a script that **edits** its argument gets that save offered back up
/// rather than losing it in a temp directory (`PanelViewController+WriteBack`).
///
/// A `combined` script can still run with nothing selected — it acts on the panel's directory
/// through the environment — so the gate is "there is somewhere to run *or* something to run on",
/// not "something is selected".
extension PanelViewController {
    // MARK: - Where a script can run

    /// The active panel's own folder on this disk, or `nil` when it has none: a server, an archive,
    /// or a virtual listing such as search results or the Trash.
    ///
    /// `writeDirectory` rather than a fresh `panel.path.backend == .local`, because it is the same
    /// question already answered once — *which real directory is this panel standing in* — and it
    /// gets the merged iCloud listing right for free, where the pane's own path is synthetic and the
    /// folder underneath it is perfectly real.
    var localPanelDirectory: String? {
        guard let directory = writeDirectory, directory.backend == .local else { return nil }
        return directory.path
    }

    /// Whether a script has anywhere to run at all: a folder on this disk, or files to be handed.
    ///
    /// Synchronous, and it has to be — it answers a menu validator and the enablement of every row
    /// in the Scripts ▸ submenu, neither of which can wait for a download. What it cannot answer is
    /// *where the files are*, which is why assembling the context moved behind `materialize`.
    var canRunUserScript: Bool {
        localPanelDirectory != nil || !handoffEntries().isEmpty
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

    /// Bring the marked set down if it is not already here, then launch `script` over it.
    ///
    /// The rows come from `handoffEntries()` — the same set Open With and Share act on, minus a
    /// folder that is not on this disk, which stands for an unknown number of objects rather than
    /// one file to hand over. A set already on this disk reaches `launch` in the same turn, with no
    /// job, no dialog and no delay, which is what keeps the ordinary local script exactly as fast as
    /// it was before this funnel existed.
    func runScript(_ script: UserScript) {
        let rows = handoffEntries()
        guard canRunUserScript else {
            presentOperationFailure(
                message: Self.runFailureMessage(script),
                detail: String(
                    localized: "The active panel isn’t a folder on this disk.",
                    comment: "Script run failure detail: no local folder to run in."
                )
            )
            return
        }
        // A per-file transform with nothing marked has nothing to do — say so rather than launching
        // zero processes silently (a combined script, by contrast, runs against the directory).
        if script.runMode == .perFile, rows.isEmpty {
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
        // `materialize` returns without calling back on an empty set, so the directory-scoped
        // `combined` run — the one shape with nothing to bring down — is answered here rather than
        // fallen through.
        guard !rows.isEmpty else {
            launch(script, over: [], at: [])
            return
        }
        materialize(rows, for: .userScript) {
            Self.runFailureMessage(script)
        } then: { [weak self] urls in
            self?.launch(script, over: rows, at: urls)
        }
    }

    /// Launch `script` over the copies standing for `rows`, watching each one first.
    ///
    /// **The watch goes on before the script does**, which is the whole of write-back working: the
    /// registry records what each copy looks like *now* and reports a later revision, so a baseline
    /// taken after the script had already rewritten the file would see nothing to offer.
    private func launch(_ script: UserScript, over rows: [FileEntry], at urls: [URL]) {
        watchForWriteBack(of: rows, at: urls)
        let context = scriptContext(selection: urls)
        UserScriptRunner.run(script, context: context, shell: resolveScriptShell()) { [weak self] outcome in
            self?.reportScriptOutcome(outcome)
        }
    }

    /// The context a run of `selection` happens in: the files, and each panel's own folder when it
    /// has one.
    ///
    /// Both directories are the *same* question asked of two panes, so both go through
    /// ``localPanelDirectory`` — the counterpart used to be asked with its own inline
    /// `backend == .local`, which is one rule in two spellings and drifted the day the first one
    /// learned about `writeDirectory`.
    func scriptContext(selection: [URL]) -> UserScriptContext {
        UserScriptContext(
            selection: selection.map(\.path),
            currentDirectory: localPanelDirectory,
            otherDirectory: host?.panelCounterpart(of: self)?.localPanelDirectory
        )
    }

    /// The one title both refusals and a failed transfer wear, so a user who marked files on a
    /// server and one who marked none read the same sentence about the same script.
    private static func runFailureMessage(_ script: UserScript) -> String {
        String(
            localized: "Can’t run “\(script.name)”",
            comment: "Script run failure title; %@ is the script name."
        )
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
        presentAsMovableWindow(UserScriptsOrganizerController())
    }

    // MARK: - Scripts submenu

    /// The items for the right-click **Scripts ▸** submenu: one per saved script (dispatched to
    /// `runUserScript`), then a rule and **Manage Scripts…**. Built fresh each time the submenu
    /// opens (`menuNeedsUpdate`), so a script added in the organizer shows up without a relaunch.
    func scriptMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let scripts = UserScriptStore.load().scripts
        let runnable = canRunUserScript
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
            // Runnable when the active pane offers somewhere to run or something to run on, and
            // never while a rename field is up (⌃-less, but a right-click item could still fire
            // mid-edit).
            return canRunUserScript && !(view.window?.firstResponder is NSText)
        case #selector(manageUserScripts(_:)):
            return true
        default:
            return nil
        }
    }
}
