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

/// The window's split controller, subclassed only to keep keyboard focus alive across a sidebar
/// collapse (PLAN.md §M8). When the source list holds first responder and the sidebar is hidden, its
/// table goes with it and AppKit drops focus to the bare window — both panes grey, and Tab dead
/// because Tab is a pane key that only fires while a pane is first responder.
///
/// `toggleSidebar(_:)` is the one funnel both the menu/palette (via the `toggleSidebar:` selector)
/// and the titlebar button already call, so overriding it here catches every collapse without
/// touching the command binding, the button, or AppKit's automatic "Show/Hide Sidebar" menu title.
/// The focus source is captured *before* `super` collapses the item — deterministic, with none of
/// the first-responder-timing guesswork a post-hoc KVO observer would need.
final class SidebarFocusSplitViewController: NSSplitViewController {
    /// Invoked after a toggle that collapsed the sidebar *while it held keyboard focus* — the
    /// condition the name encodes. The host hands focus to the active pane so keyboard control
    /// survives the collapse.
    var onFocusedCollapse: (() -> Void)?

    override func toggleSidebar(_ sender: Any?) {
        let sidebarItem = splitViewItems.first { $0.behavior == .sidebar }
        let hadFocus = sidebarItem.map { item in
            (view.window?.firstResponder as? NSView)?.isDescendant(of: item.viewController.view) ?? false
        } ?? false
        super.toggleSidebar(sender)
        if hadFocus, sidebarItem?.isCollapsed == true {
            onFocusedCollapse?()
        }
    }
}
