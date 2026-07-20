import AppKit

/// The window-level half of keyboard access to the sidebar (PLAN.md §M8). The catalog command
/// `view.focusSidebar` (⌥⌘S) dispatches here through the responder chain — the same path
/// `view.terminal` uses to reach the window controller — because focusing the source list is a
/// window concern (it must reveal a collapsed sidebar and know the active pane's location), not a
/// pane one.
extension BrowserWindowController {
    /// Reveal the sidebar if it's collapsed, then hand it keyboard focus with the cursor on the
    /// active pane's current location (if that place is pinned). Focusing an invisible list would be
    /// a dead keystroke, so the reveal comes first; it is not animated, because the user asked to
    /// *use* the sidebar now, not to watch it slide in.
    @objc func focusSidebar(_ sender: Any?) {
        if sidebarSplitItem.isCollapsed {
            sidebarSplitItem.isCollapsed = false
        }
        sidebar.focusFromKeyboard(preferring: focusedPanel.panel.path)
    }
}
