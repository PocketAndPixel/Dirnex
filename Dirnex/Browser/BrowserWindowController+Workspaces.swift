import AppKit
import DirnexCore

/// The window's `PanelHost` workspace surface (PLAN.md §M3 "Workspaces: save/restore both
/// panels with all tabs"). A workspace spans both panes, which no single pane can see, so the
/// window is the natural owner: it snapshots and restores the two panes together. Persistence
/// and the menu/palette UI live pane-side in `PanelViewController+Workspaces` and the shared
/// `WorkspaceStore`.
extension BrowserWindowController {
    func captureWorkspace(named name: String) -> Workspace {
        Workspace(
            name: name,
            left: leftPanel.workspaceSnapshot(),
            right: rightPanel.workspaceSnapshot()
        )
    }

    func applyWorkspace(_ workspace: Workspace) {
        leftPanel.restore(workspacePane: workspace.left)
        rightPanel.restore(workspacePane: workspace.right)
        // Restore lands focus in the left pane, matching a fresh launch, and re-activates it
        // through the pane's first-responder callback.
        leftPanel.focusTable()
    }
}
