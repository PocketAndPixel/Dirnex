import AppKit
import DirnexCore

/// The sidebar's Favorites section: rendering a pinned folder and managing it in place
/// (PLAN.md §M8 "the favorites *becomes* the sidebar's Favorites section"). Split out of
/// `SidebarViewController` so that file stays under the length limit; `menuNeedsUpdate` and
/// `tableView(_:viewFor:row:)` (in the main file) dispatch here for a favorite row.
extension SidebarViewController {
    // MARK: - Rendering

    /// Build (or reuse) a pinned-folder cell.
    ///
    /// Deliberately **no trailing delete button**, unlike the saved-search and server rows that
    /// share this cell type. Those sections hold a handful of rows; Favorites opens seeded with
    /// eight, and eight always-visible trash buttons turn the top of the sidebar into a row of
    /// hazards over the folders the user reaches for most. Removal lives in the right-click menu,
    /// which is where Finder puts it too.
    func favoriteCell(for entry: FavoriteEntry) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        cell.configure(
            name: SidebarPlacePresentation.title(for: .favorite(entry)),
            image: Self.favoriteIcon(for: entry),
            canEject: false,
            tooltip: entry.path.path
        )
        cell.onEject = nil
        return cell
    }

    /// The glyph for a pinned folder, rendered at the source list's size. *Which* symbol it is —
    /// a standard place's own, a plain folder, or a protocol glyph for a pin outside the local
    /// filesystem — is `SidebarPlacePresentation`'s, so the Go ▸ Places menu marks the same pin
    /// the same way (PLAN.md §M20).
    private static func favoriteIcon(for entry: FavoriteEntry) -> NSImage {
        let symbol = SidebarPlacePresentation.symbolName(for: .favorite(entry)) ?? "folder"
        return templateSymbol(symbol, pointSize: 15)
    }

    // MARK: - Right-click menu

    /// Populate `menu` with the Open / Rename / Remove items for `entry`.
    func buildFavoriteMenu(_ menu: NSMenu, for entry: FavoriteEntry) {
        menu.addItem(favoriteMenuItem(
            String(
                localized: "Open",
                comment: "Sidebar favorite context-menu item: open the folder."
            ),
            #selector(openFavoriteItem(_:)),
            entry.path
        ))
        menu.addItem(.separator())
        menu.addItem(favoriteMenuItem(
            String(
                localized: "Rename…",
                // Verbatim at all three sidebar sites that key this string — see the note in
                // `SidebarViewController+Vaults`.
                comment: "Sidebar context-menu item: the Rename verb."
            ),
            #selector(renameFavoriteItem(_:)),
            entry.path
        ))
        menu.addItem(favoriteMenuItem(
            String(
                localized: "Remove from Sidebar",
                comment: "Sidebar favorite context-menu item: unpin the folder."
            ),
            #selector(removeFavoriteItem(_:)),
            entry.path
        ))
    }

    /// One management item, carrying the entry's *path* — its identity in the pin list — so a
    /// mid-open store change can't act on the wrong (index-shifted) row, mirroring the
    /// saved-search and server menus.
    private func favoriteMenuItem(_ title: String, _ action: Selector, _ path: VFSPath) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = path
        return item
    }

    /// Open goes through `activate(_:)` — the same funnel a click on the row uses — rather than
    /// handing the delegate a bare path of its own. It is one rule with two spellings otherwise,
    /// and the second one silently loses what a pin on a server needs to reconnect.
    ///
    /// The entry is re-read from the store by its path, mirroring `renameFavoriteItem` right below:
    /// the item deliberately carries the path rather than the entry so a mid-open store change acts
    /// on the right row. A pin unpinned while the menu was open falls back to the bare path, which
    /// is what this did for every pin before the endpoint existed.
    @objc private func openFavoriteItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? VFSPath else { return }
        let stored = FavoritesStore.load().entries.first { $0.path == path }
        activate(.favorite(stored ?? FavoriteEntry(path: path)))
    }

    @objc private func renameFavoriteItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? VFSPath,
              let current = FavoritesStore.load().entries.first(where: { $0.path == path })?.name
        else { return }
        // The prompt is a sheet, so it is awaited rather than run inline.
        Task { @MainActor in
            guard let newName = await promptForFavoriteRename(current: current),
                  newName != current else { return }
            var favorites = FavoritesStore.load()
            favorites.rename(path: path, to: newName)
            FavoritesStore.save(favorites)
        }
    }

    /// Remove a pin. No confirmation: unlike deleting a saved search — which discards a query the
    /// user composed and cannot get back — this discards a pointer to a folder that is still
    /// exactly where it was, and re-adding it is one drag. A sheet here would be theater.
    @objc private func removeFavoriteItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? VFSPath else { return }
        var favorites = FavoritesStore.load()
        if favorites.remove(path: path) { FavoritesStore.save(favorites) }
    }

    /// Ask for a new label, prefilled with the current one; `nil` on cancel or an empty name.
    private func promptForFavoriteRename(current: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Rename Favorite",
            comment: "Title of the dialog that renames a pinned sidebar favorite."
        )
        alert.informativeText = String(
            localized: "This renames the sidebar row. The folder itself is not renamed.",
            comment: "Body of the rename-favorite dialog, clarifying the folder is untouched."
        )
        alert.addButton(withTitle: String(
            localized: "Rename",
            comment: "Confirm button of a rename dialog."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel()

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.keepToOneLine()
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = await alert.runSheet(over: view.window) { field.selectText(nil) }
        guard response == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
