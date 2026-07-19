import AppKit
import DirnexCore

/// The terminal drawer's place in the window, and the two directions it stays in step with the
/// panes (PLAN.md §M6 "bottom pane following active panel's cwd; 'cd sync back'").
///
/// The window owns this for the same reason it owns Quick View: the drawer belongs to *neither*
/// pane — it follows whichever is active, and a single pane can't see which that is. Both
/// directions are the core's policy (`ShellWorkingDirectory`); all this file decides is when to
/// ask and which pane is on the other end.
extension BrowserWindowController: TerminalDrawerDelegate {
    // MARK: - Layout

    /// Stack the panes over the drawer, inside the outer sidebar split. Called from `init`, before
    /// the stack is handed to the outer split as its second item.
    func installTerminalDrawer() {
        paneStackSplitViewController.splitView.isVertical = false
        paneStackSplitViewController.splitView.dividerStyle = .thin
        paneStackSplitViewController.splitView.autosaveName = Self.terminalDrawerAutosaveName
        // Read this before the split view lays out (which writes its autosave): a missing entry
        // means nobody has ever opened the drawer, so the first open picks its own height.
        let geometryKey = "NSSplitView Subview Frames \(Self.terminalDrawerAutosaveName)"
        shouldSizeTerminalDrawer = UserDefaults.standard.object(forKey: geometryKey) == nil

        let panesItem = NSSplitViewItem(viewController: panesSplitViewController)
        panesItem.canCollapse = false
        paneStackSplitViewController.addSplitViewItem(panesItem)

        terminalDrawer.delegate = self
        terminalDrawerItem = NSSplitViewItem(viewController: terminalDrawer)
        terminalDrawerItem.canCollapse = true
        // Closed on a fresh install. A saved geometry wins over this — a drawer left open is one
        // the user wants open, exactly as the sidebar behaves.
        terminalDrawerItem.isCollapsed = true
        terminalDrawerItem.minimumThickness = 80
        // Higher than the panes' 250, so growing the window grows the *files* and the drawer keeps
        // the height the user gave it. Xcode's debug area, and every terminal drawer, does this.
        terminalDrawerItem.holdingPriority = NSLayoutConstraint.Priority(260)
        paneStackSplitViewController.addSplitViewItem(terminalDrawerItem)
    }

    /// Autosave for the drawer's height and open/closed state. Versioned like the panes' own name
    /// so a later layout change can start clean rather than inherit a stale geometry.
    private static var terminalDrawerAutosaveName: String { "BrowserTerminalDrawerV1" }

    /// The height the drawer opens at when it has never been opened before: enough for a prompt,
    /// a command, and its output to be worth reading — roughly a dozen lines at the drawer's
    /// 12pt Menlo — while still leaving the panes the bulk of the window. Only ever a starting
    /// point; a drag persists under the autosave name and wins from then on.
    private static var defaultTerminalDrawerHeight: CGFloat { 200 }

    /// Give the drawer its opening height, after the stack has laid out so the split view knows
    /// its real bounds — the same shape as `centerPanesDivider`.
    private func sizeTerminalDrawerToDefault() {
        let splitView = paneStackSplitViewController.splitView
        splitView.layoutSubtreeIfNeeded()
        let available = splitView.bounds.height - splitView.dividerThickness
        // A window too short to give the panes anything back keeps AppKit's own answer.
        guard available > Self.defaultTerminalDrawerHeight * 2 else { return }
        splitView.setPosition(available - Self.defaultTerminalDrawerHeight, ofDividerAt: 0)
    }

    // MARK: - Opening and closing

    /// ⌃` — View ▸ Terminal Drawer. Opens the drawer (spawning the shell on the first open, in the
    /// active pane's directory so nothing is typed) and hands it focus; closing gives focus back to
    /// the pane, since a hidden terminal holding the keyboard would swallow every keystroke.
    ///
    /// Reached through the responder chain, like every registry command. It lands here rather than
    /// on a pane deliberately: the window controller is in the chain from *both* the panes and the
    /// terminal, so ⌃` closes the drawer from inside the drawer.
    @objc func toggleTerminalDrawer(_ sender: Any?) {
        let willOpen = terminalDrawerItem.isCollapsed
        if willOpen {
            terminalDrawer.startShellIfNeeded(in: focusedPanel.panel.path)
        }
        if willOpen, shouldSizeTerminalDrawer {
            // The very first open, with no saved height to restore. Uncollapsing alone would give
            // the item its minimum thickness — four lines, which reads as broken rather than as a
            // terminal — so seed a real one. Unanimated: the slide and an immediate divider move
            // fight each other, and this happens exactly once in the app's life.
            shouldSizeTerminalDrawer = false
            terminalDrawerItem.isCollapsed = false
            sizeTerminalDrawerToDefault()
        } else {
            terminalDrawerItem.animator().isCollapsed = !willOpen
        }
        if willOpen {
            terminalDrawer.focusTerminal()
            // The shell may have been left somewhere else while the drawer was hidden, or the
            // panes may have moved on since — reconcile on the way in.
            syncTerminalToActivePanel()
        } else {
            focusedPanel.focusTable()
        }
    }

    /// Start the shell for a drawer the autosave restored open, at window-show time.
    func startTerminalShellIfDrawerIsOpen() {
        guard !terminalDrawerItem.isCollapsed else { return }
        terminalDrawer.startShellIfNeeded(in: focusedPanel.panel.path)
    }

    /// Kill the drawer's shell as the app goes away. The pseudo-terminal closing would hang it up
    /// on its own, but only once the master descriptor is actually released — signalling it is the
    /// difference between a shell that ends when the user quits and one that lingers, reparented,
    /// holding a directory open behind their back.
    func terminateTerminalShell() {
        terminalDrawer.terminateShell()
    }

    /// Whether the drawer's terminal holds the keyboard right now. The panes ask before letting a
    /// ⌃-key shortcut of theirs fire — see `PanelViewController.validateMenuItem`.
    var isTerminalFocused: Bool {
        terminalDrawerItem != nil && !terminalDrawerItem.isCollapsed && terminalDrawer.isTerminalFocused
    }

    // MARK: - Panel → shell

    /// Type the `cd` that walks the shell to the active pane, if it needs one. A no-op while the
    /// drawer is closed: an invisible shell being marched around after every keystroke of browsing
    /// would fill a history the user never asked us to write, and the drawer reconciles on opening
    /// anyway.
    func syncTerminalToActivePanel() {
        guard terminalDrawerItem != nil, !terminalDrawerItem.isCollapsed else { return }
        terminalDrawer.followPanel(to: focusedPanel.panel.path)
    }

    // MARK: - Shell → panel

    /// The shell walked somewhere (`cd`, or a script that did it) — so the active pane follows.
    ///
    /// The decision is the core's: `directoryToFollow` returns `nil` when the pane is already
    /// showing that directory (comparing *resolved* paths on both sides, so a pane on `/tmp` and a
    /// shell reporting `/private/tmp` are understood to be the same place and nothing moves), and
    /// `nil` for a pane that isn't on the local filesystem at all — an archive or an SFTP server
    /// has no directory a local shell could correspond to.
    func terminalDrawer(_ drawer: TerminalDrawerViewController, shellDidMoveTo directory: String) {
        let target = focusedPanel
        guard let destination = ShellWorkingDirectory.directoryToFollow(
            shellDirectory: directory,
            paneDirectory: target.panel.path,
            resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        ) else { return }
        // Navigate without taking the keyboard: the user is typing in the shell, and a pane that
        // stole focus mid-command would send the rest of their line to a file table.
        target.navigate(to: destination)
    }

    /// The shell exited (`exit`, ⌃D). Close the drawer and give the pane its keyboard back; the
    /// next ⌃` spawns a fresh shell in a clean screen.
    ///
    /// Closing rather than showing a dead prompt is the honest reading of `exit`: the session the
    /// user ended is gone, and a drawer still sitting there implies otherwise. This fires whether
    /// the drawer was open or not — a shell can exit while hidden — so the collapse is guarded but
    /// the reset is not.
    func terminalDrawerShellDidExit(_ drawer: TerminalDrawerViewController) {
        if terminalDrawerItem != nil, !terminalDrawerItem.isCollapsed {
            terminalDrawerItem.animator().isCollapsed = true
            focusedPanel.focusTable()
        }
        drawer.prepareForRespawn()
    }
}
