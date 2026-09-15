import AppKit

/// View ▸ Filter (⌥⌘F): the bar that narrows a table or a JSON tree in Quick View to what contains some
/// text (2026-09-15). Everything about the filter itself is the surface's (`QuickViewFilterHost`); this
/// is the window's half, for the reason every Quick View command is the window's — at full size the
/// preview is a sibling of the panes, so a pane-hosted selector has no target once somebody clicks
/// into it. The selector and the command's id keep the name they had when only a table could be
/// filtered: the id is a translation key.
///
/// A menu item and not only a key, so the command can be found, rebound, and is disabled whenever
/// there is nothing on screen to filter.
extension BrowserWindowController {
    @objc func filterQuickViewTable(_ sender: Any?) {
        guard let surface = visibleQuickViewSurface?.filterableSurface else { return }
        // The list the arrows walk is the focused pane's, in every mode — in pane mode that is not
        // the pane the preview covers — and it is where the keyboard goes when the bar lets go of it.
        surface.returnKeyboard = { [weak self] in self?.focusedPanel.focusTable() }
        surface.beginFiltering()
    }

    /// Whether there is a table or a tree on screen to filter — the menu item's enabled state, asked
    /// through the same property the action reaches the surface by.
    var canFilterQuickViewTable: Bool {
        visibleQuickViewSurface?.filterableSurface != nil
    }
}
