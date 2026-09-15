import AppKit

/// View ▸ Filter Table (⌥⌘F): the bar that narrows a table in Quick View to the rows containing some
/// text (2026-09-15). Everything about the filter itself is `QuickViewTableView+Filter`'s; this is the
/// window's half, for the reason every Quick View command is the window's — at full size the preview
/// is a sibling of the panes, so a pane-hosted selector has no target once somebody clicks into it.
///
/// A menu item and not only a key, so the command can be found, rebound, and is disabled whenever
/// there is no table on screen to filter.
extension BrowserWindowController {
    @objc func filterQuickViewTable(_ sender: Any?) {
        guard let table = visibleQuickViewSurface?.filterableTable else { return }
        // The list the arrows walk is the focused pane's, in every mode — in pane mode that is not
        // the pane the preview covers — and it is where the keyboard goes when the bar lets go of it.
        table.returnKeyboard = { [weak self] in self?.focusedPanel.focusTable() }
        table.beginFiltering()
    }

    /// Whether there is a table on screen to filter — the menu item's enabled state, asked through
    /// the same property the action reaches the table by.
    var canFilterQuickViewTable: Bool {
        visibleQuickViewSurface?.filterableTable != nil
    }
}
