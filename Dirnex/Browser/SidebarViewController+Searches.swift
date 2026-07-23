import AppKit
import DirnexCore

/// The sidebar's saved-search management surface: the right-click menu (Run / Rename / Delete) and
/// its delete confirmation. Split out of `SidebarViewController` so that file stays under the length
/// limit once the Servers section joins it; `menuNeedsUpdate` (in the main file) dispatches here for
/// a saved-search row.
extension SidebarViewController {
    // MARK: - Rendering

    /// Build (or reuse) a saved-search cell; removal is a right-click-menu action, not a per-row
    /// button.
    func savedSearchCell(for search: SavedSearch) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        cell.configure(
            name: search.name,
            image: Self.savedSearchIcon,
            canEject: false,
            tooltip: savedSearchTooltip(search)
        )
        cell.onEject = nil
        return cell
    }

    /// A magnifying-glass SF Symbol so a saved search reads as a query, not a folder. Template
    /// so the source list tints it with the row's text color like the favorite glyphs.
    static let savedSearchIcon = templateSymbol(
        "magnifyingglass",
        pointSize: 14,
        describedAs: String(
            localized: "Saved search",
            comment: "Accessibility label for a saved-search sidebar row's glyph."
        )
    )

    /// A tooltip describing where a saved search runs — the scope folder, or "Everywhere".
    private func savedSearchTooltip(_ search: SavedSearch) -> String {
        guard let scope = search.scope else {
            return String(
                localized: "Search everywhere",
                comment: "Tooltip on a saved search with no scope folder — it searches the whole Mac."
            )
        }
        return String(
            localized: "Search in “\(scope.lastComponent)”",
            comment: "Tooltip on a scoped saved search; %@ is the scope folder's name."
        )
    }

    // MARK: - Right-click menu

    /// Populate `menu` with the Run / Rename / Delete items for `search`.
    func buildSavedSearchMenu(_ menu: NSMenu, for search: SavedSearch) {
        menu.addItem(savedSearchMenuItem(
            String(
                localized: "Run Search",
                comment: "Saved-search context-menu item: run the query."
            ),
            #selector(runSavedSearchItem(_:)),
            search.name
        ))
        menu.addItem(.separator())
        menu.addItem(savedSearchMenuItem(
            String(localized: "Rename…", comment: "Saved-search context-menu item: rename it."),
            #selector(renameSavedSearchItem(_:)),
            search.name
        ))
        menu.addItem(savedSearchMenuItem(
            String(localized: "Delete", comment: "Saved-search context-menu item: delete it."),
            #selector(deleteSavedSearchItem(_:)),
            search.name
        ))
    }

    /// One management item, carrying the search's *name* so a mid-open store change can't act
    /// on the wrong (index-shifted) search — mirroring the favorites/workspace popups.
    private func savedSearchMenuItem(_ title: String, _ action: Selector, _ name: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = name
        return item
    }

    @objc private func runSavedSearchItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let search = SavedSearchStore.load().search(named: name) else { return }
        delegate?.sidebar(self, didActivateSavedSearch: search)
    }

    @objc private func renameSavedSearchItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let newName = promptForSavedSearchRename(current: name), newName != name else { return }
        var store = SavedSearchStore.load()
        if store.rename(name: name, to: newName) {
            SavedSearchStore.save(store)
        } else {
            presentSavedSearchRenameCollision(newName)
        }
    }

    @objc private func deleteSavedSearchItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        confirmDeleteSavedSearch(named: name)
    }

    /// Confirm before removing a saved search — the context-menu Delete's path. Presented as a
    /// window sheet when possible.
    func confirmDeleteSavedSearch(named name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Delete “\(name)”?",
            comment: "Saved-search delete confirmation title; %@ is the search's name."
        )
        alert.informativeText = String(
            localized: "This removes the saved search from the sidebar. No files are deleted.",
            comment: "Body of the delete-saved-search confirmation."
        )
        alert.addButton(withTitle: String(
            localized: "Delete",
            comment: "Confirm button that deletes a saved search."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))

        let commit = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            var store = SavedSearchStore.load()
            if store.remove(name: name) { SavedSearchStore.save(store) }
            _ = self
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: commit)
        } else {
            commit(alert.runModal())
        }
    }

    /// Ask for a new name, prefilled with the current one; `nil` on cancel or an empty name.
    private func promptForSavedSearchRename(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Rename Saved Search",
            comment: "Title of the dialog that renames a saved search."
        )
        alert.addButton(
            withTitle: String(localized: "Rename", comment: "Confirm button of a rename dialog.")
        )
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// A rename that collides with a *different* saved search is refused by the model; tell the
    /// user rather than silently dropping it.
    private func presentSavedSearchRenameCollision(_ name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "“\(name)” is already taken",
            comment: "Rename-collision title; %@ is the name the user typed."
        )
        alert.informativeText = String(
            localized: "Another saved search already uses that name. Pick a different one.",
            comment: "Body of the saved-search rename-collision alert."
        )
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
