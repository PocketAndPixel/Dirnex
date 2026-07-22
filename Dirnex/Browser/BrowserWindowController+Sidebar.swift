import AppKit
import DirnexCore

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

// MARK: - SidebarViewControllerDelegate

extension BrowserWindowController: SidebarViewControllerDelegate {
    /// A sidebar click points the active pane at the chosen place/volume, then hands
    /// keyboard focus back to that pane so browsing continues without a mouse.
    func sidebar(_ sidebar: SidebarViewController, didActivate path: VFSPath) {
        let target = activePanel ?? leftPanel
        target.navigate(to: path)
        target.focusTable()
    }

    /// A saved search re-runs its query in the active pane, opening the hits in a virtual
    /// results tab, then hands focus back so browsing the results continues without a mouse.
    func sidebar(_ sidebar: SidebarViewController, didActivateSavedSearch savedSearch: SavedSearch) {
        let target = activePanel ?? leftPanel
        target.runSavedSearch(savedSearch)
        target.focusTable()
    }

    /// Recents opens the recently-used files as a virtual results tab in the active pane, the way a
    /// saved search does (PLAN.md §M8), then hands focus back for keyboard browsing of the results.
    func sidebarDidActivateRecents(_ sidebar: SidebarViewController) {
        let target = activePanel ?? leftPanel
        target.showRecents()
        target.focusTable()
    }

    /// The Trash opens as a merged listing of every volume's trash in the active pane (PLAN.md §M8),
    /// then hands focus back so it can be walked — and emptied — from the keyboard.
    func sidebarDidActivateTrash(_ sidebar: SidebarViewController) {
        let target = activePanel ?? leftPanel
        target.showTrash()
        target.focusTable()
    }

    /// iCloud Drive opens in the active pane as the merge Finder shows — the CloudDocs container's
    /// loose files plus each app's own document folder (PLAN.md §M9) — then hands focus back for
    /// keyboard browsing. Unlike the Trash it replaces the pane's listing rather than opening a tab
    /// beside it: it is a place people browse repeatedly, and a tab per click would stack up.
    func sidebarDidActivateICloud(_ sidebar: SidebarViewController) {
        let target = activePanel ?? leftPanel
        target.showICloudDrive()
        target.focusTable()
    }

    /// "Empty Trash…" erases every volume's trash, after a confirmation naming the count. Run
    /// through the active pane because that is what owns the backend, the progress reporting and
    /// the re-list — a pane already showing the Trash must not be left displaying items that no
    /// longer exist.
    func sidebarDidRequestEmptyTrash(_ sidebar: SidebarViewController) {
        (activePanel ?? leftPanel).emptyTrash()
    }

    /// A saved server connects (SFTP) or mounts (SMB) in the active pane and browses it. The
    /// connect/mount is async and, on completion, both navigates *and* focuses the pane itself,
    /// so grabbing focus here (before the connection resolves) would be premature.
    func sidebar(_ sidebar: SidebarViewController, didActivateServer server: ServerConnection) {
        (activePanel ?? leftPanel).connect(to: server)
    }

    /// A tag row searches for the files carrying it and shows them in the active pane, the way a
    /// saved search does — a tag is a query, not a place.
    func sidebar(_ sidebar: SidebarViewController, didActivateTag tag: FinderTag) {
        let target = activePanel ?? leftPanel
        target.runTagSearch(tag)
        target.focusTable()
    }

    /// "Edit…" on a saved server re-opens the connect prompt prefilled from it, in the active pane.
    func sidebar(_ sidebar: SidebarViewController, didEditServer server: ServerConnection) {
        (activePanel ?? leftPanel).editServer(server)
    }

    /// An empty-space / header click in the sidebar re-focuses the active pane so its keyboard
    /// focus — and the responder-chain file commands (F5/F6/F8) — survive the click.
    func sidebarDidClickEmptyArea(_ sidebar: SidebarViewController) {
        (activePanel ?? leftPanel).focusTable()
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
final class SidebarFocusSplitViewController: LockableDividerSplitViewController {
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
