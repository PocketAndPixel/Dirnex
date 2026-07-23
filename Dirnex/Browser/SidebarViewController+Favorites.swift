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
            name: entry.name,
            image: Self.favoriteIcon(for: entry.path),
            canEject: false,
            tooltip: entry.path.path
        )
        cell.onEject = nil
        return cell
    }

    /// The glyph for a pinned folder: its standard-place symbol when the path is one of the
    /// well-known folders, otherwise a plain folder — or a protocol glyph for a pin that lives
    /// outside the local filesystem, so a remote or in-archive favorite doesn't pretend to be a
    /// local directory.
    private static func favoriteIcon(for path: VFSPath) -> NSImage {
        if let kind = SidebarLocations.standardKind(for: path) {
            return templateSymbol(symbolName(for: kind), pointSize: 15)
        }
        guard path.backend == .local else {
            return templateSymbol(path.backend.isArchive ? "doc.zipper" : "network", pointSize: 15)
        }
        return templateSymbol("folder", pointSize: 15)
    }

    /// A monochrome SF Symbol standing in for each standard folder, so Documents, Downloads,
    /// Music and the rest read at a glance instead of all sharing the generic folder icon.
    private static func symbolName(for kind: FavoritePlace.Kind) -> String {
        switch kind {
        case .home: "house"
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc"
        case .downloads: "arrow.down.circle"
        case .pictures: "photo"
        case .music: "music.note"
        case .movies: "film"
        case .applications: "square.grid.3x3.fill"
        }
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
                comment: "Sidebar favorite context-menu item: rename the row."
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

    @objc private func openFavoriteItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? VFSPath else { return }
        delegate?.sidebar(self, didActivate: path)
    }

    @objc private func renameFavoriteItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? VFSPath,
              let current = FavoritesStore.load().entries.first(where: { $0.path == path })?.name,
              let newName = promptForFavoriteRename(current: current), newName != current else {
            return
        }
        var favorites = FavoritesStore.load()
        favorites.rename(path: path, to: newName)
        FavoritesStore.save(favorites)
    }

    /// Remove a pin. No confirmation: unlike deleting a saved search — which discards a query the
    /// user composed and cannot get back — this discards a pointer to a folder that is still
    /// exactly where it was, and re-adding it is one drag. A sheet here would be theatre.
    @objc private func removeFavoriteItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? VFSPath else { return }
        var favorites = FavoritesStore.load()
        if favorites.remove(path: path) { FavoritesStore.save(favorites) }
    }

    /// Ask for a new label, prefilled with the current one; `nil` on cancel or an empty name.
    private func promptForFavoriteRename(current: String) -> String? {
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

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
