import AppKit
import DirnexCore

/// Per-panel navigation history (PLAN.md §M3 "Per-panel history (Alt+Down list; Cmd+[ /
/// Cmd+] back/forward)"). Each tab owns a `NavigationHistory` trail; this drives it from the
/// keyboard, menu bar, and Cmd+K palette. The pane owns the actions because the trail is
/// tab-relative — Cmd+[ steps *this* tab back, and the Alt+Down popup lists *this* tab's
/// visited directories. Walking the trail navigates without recording, so back/forward move
/// through history rather than rewriting it (the browser model in `NavigationHistory`).
extension PanelViewController {
    // MARK: - Trail state (drives the titlebar Back/Forward buttons' enabled state)

    /// Whether ⌘[ / the Back button can step this tab's trail back.
    var canGoBack: Bool { tabs[activeTabIndex].history.canGoBack }
    /// Whether ⌘] / the Forward button can step this tab's trail forward.
    var canGoForward: Bool { tabs[activeTabIndex].history.canGoForward }

    // MARK: - Commands (dispatched to the focused pane via the responder chain)

    /// ⌘[ — step back to the previously visited directory in this tab's trail.
    @objc func goBack(_ sender: Any?) {
        guard let path = tabs[activeTabIndex].history.back() else { return }
        navigate(to: path, recordHistory: false)
    }

    /// ⌘] — step forward to the directory you last stepped back from.
    @objc func goForward(_ sender: Any?) {
        guard let path = tabs[activeTabIndex].history.forward() else { return }
        navigate(to: path, recordHistory: false)
    }

    /// ⌥↓ — drop the history trail just under the path bar (TC's Alt+Down), newest at the
    /// top with the current directory check-marked; picking one jumps straight to it.
    @objc func showHistory(_ sender: Any?) {
        let menu = buildHistoryMenu()
        // Drop the menu from the path bar's bottom edge, matching the favorites popup.
        let origin = NSPoint(x: 8, y: pathBar.isFlipped ? pathBar.bounds.maxY : 0)
        menu.popUp(positioning: nil, at: origin, in: pathBar)
    }

    // MARK: - Popup menu

    private func buildHistoryMenu() -> NSMenu {
        let menu = NSMenu()
        let history = tabs[activeTabIndex].history
        // Newest first (most recently visited on top). The trail's own index is carried on
        // each item so a jump lands precisely even though the display order is reversed.
        for index in history.entries.indices.reversed() {
            menu.addItem(
                historyItem(for: history.entries[index], index: index, current: history.currentIndex)
            )
        }
        return menu
    }

    private func historyItem(for path: VFSPath, index: Int, current: Int) -> NSMenuItem {
        let item = NSMenuItem(
            title: path.isRoot ? "Macintosh HD" : path.lastComponent,
            action: #selector(jumpToHistoryEntry(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = index
        item.toolTip = path.path
        // Mark the directory the pane is currently showing.
        item.state = index == current ? .on : .off
        let icon = NSWorkspace.shared.icon(forFile: path.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    // MARK: - Actions

    @objc private func jumpToHistoryEntry(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              let path = tabs[activeTabIndex].history.jump(to: index) else { return }
        navigate(to: path, recordHistory: false)
        focusTable()
    }
}
