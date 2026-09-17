import AppKit

/// View ▸ Filter (⌥⌘F): the bar that narrows a table or a JSON tree in Quick View to what contains some
/// text (2026-09-15), and that finds text in place in a text preview, a rendered page and a PDF
/// (2026-09-17). The item names which of the two it would do (`validateQuickViewFilterItem`, 2026-09-18).
/// Everything about the filter itself is the surface's (`QuickViewFilterHost`); this
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

    /// Whether there is a table, a tree or a text on screen to filter — the menu item's enabled state, asked
    /// through the same property the action reaches the surface by.
    var canFilterQuickViewTable: Bool {
        visibleQuickViewSurface?.filterableSurface != nil
    }

    /// Enable the item, and name it for what ⌥⌘F would actually do to what is on screen: **Find…**
    /// over a text, a rendered page or a PDF, where the bar steps through matches in place, and the
    /// catalog's own **Filter** over a table or a tree, where it narrows the rows.
    ///
    /// The same reason Edit and Compare By Contents retitle themselves (`validateEditItem`): one
    /// title for two different things tells the user the wrong one half the time, and "Filter" is the
    /// wrong one for the three surfaces that do not filter anything. The **palette keeps the catalog
    /// title**, which is what its fuzzy search matches against — and `Command.keywords` already
    /// carries "find" and "search", so ⌘K finds this command by either word whichever is on screen.
    ///
    /// The filter branch reads the title back from `LocalizedCatalog` rather than spelling it: the
    /// registry's own string is already translated into all fourteen languages, and a second literal
    /// saying "Filter" is a display string existing twice, which gets localized once
    /// (docs/NOTES.md ▸ Localization).
    func validateQuickViewFilterItem(_ menuItem: NSMenuItem) -> Bool {
        let surface = visibleQuickViewSurface?.filterableSurface
        menuItem.title = Self.filterItemTitle(finding: surface is (any QuickViewFindHost))
            ?? menuItem.title
        return surface != nil
    }

    /// The item's title for each of the two things ⌥⌘F does. Split from the validation above so the
    /// choice can be tested without a window and a live preview behind it, the way
    /// `AlertKeyCatcher.button(for:)` decides and something else clicks.
    ///
    /// `nil` only where the catalog cannot answer, which is an id that is not in the registry — the
    /// caller then leaves the title alone rather than blanking a menu item.
    static func filterItemTitle(finding: Bool) -> String? {
        guard !finding else {
            return String(
                localized: "Find…",
                comment: """
                View ▸ Filter menu title while Quick View is showing a text, a rendered page or a PDF, \
                where ⌥⌘F finds in place rather than narrowing rows.
                """
            )
        }
        return LocalizedCatalog.command(for: filterCommandID)?.title
    }

    /// The registry id behind View ▸ Filter. It keeps the name it had when only a table could be
    /// filtered, because it is a translation key (`CommandCatalogCategories`).
    private static let filterCommandID = "view.quickViewFilterTable"
}
