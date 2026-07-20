import AppKit
import DirnexCore

/// The directory favorites (PLAN.md §M3 "Directory favorites (Ctrl+D): pin, reorder, jump") —
/// Total Commander's Ctrl+D popup of pinned folders, also reachable from the Go menu and the
/// Cmd+K palette. The pane owns the actions because they're pane-relative: a jump lands in
/// *this* pane and Add pins *this* pane's folder. The shared list lives in `FavoritesStore`.
///
/// This popup is now the *keyboard* face of the pin list; its visible face is the sidebar's
/// Favorites section, which since M8 renders the same `FavoritesStore` (PLAN.md §M8). Reorder,
/// rename and remove live there — dragging a row, or its right-click menu — which is why the
/// organizer sheet this popup used to open no longer exists.
extension PanelViewController {
    // MARK: - Commands (dispatched to the focused pane via the responder chain)

    /// ⌃D — drop the favorites just under the path bar: one item per pinned folder (jump on
    /// pick), then Add/Remove the current folder and Organize…
    @objc func showFavorites(_ sender: Any?) {
        let menu = buildFavoritesMenu()
        // Drop the menu from the path bar's bottom edge, regardless of its flip orientation.
        let origin = NSPoint(x: 8, y: pathBar.isFlipped ? pathBar.bounds.maxY : 0)
        menu.popUp(positioning: nil, at: origin, in: pathBar)
    }

    /// "Add to Favorites" — pin this pane's current folder (a no-op if it's already pinned).
    /// The palette-discoverable sibling of the popup's Add item.
    @objc func addToFavorites(_ sender: Any?) {
        var favorites = FavoritesStore.load()
        if favorites.add(FavoriteEntry(path: panel.path)) {
            FavoritesStore.save(favorites)
        }
    }

    // MARK: - Popup menu

    private func buildFavoritesMenu() -> NSMenu {
        let menu = NSMenu()
        let favorites = FavoritesStore.load()

        if favorites.entries.isEmpty {
            let empty = NSMenuItem(title: "No Pinned Folders", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, entry) in favorites.entries.enumerated() {
                menu.addItem(favoritesItem(for: entry, index: index))
            }
        }

        menu.addItem(.separator())

        let pinned = favorites.contains(panel.path)
        let toggle = NSMenuItem(
            title: pinned ? "Remove Current Folder" : "Add Current Folder",
            action: #selector(toggleCurrentFolderPin(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        return menu
    }

    /// One jump item, carrying its target path so a mid-open store change can't send the
    /// pane to the wrong (index-shifted) folder. The first nine entries get a bare 1–9
    /// accelerator, usable while the menu is open (TC's number-key jump).
    private func favoritesItem(for entry: FavoriteEntry, index: Int) -> NSMenuItem {
        let item = NSMenuItem(
            title: entry.name,
            action: #selector(jumpToFavoriteEntry(_:)),
            keyEquivalent: index < 9 ? String(index + 1) : ""
        )
        item.keyEquivalentModifierMask = []
        item.target = self
        item.representedObject = entry.path
        item.toolTip = entry.path.path
        let icon = NSWorkspace.shared.icon(forFile: entry.path.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    // MARK: - Actions

    @objc private func jumpToFavoriteEntry(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? VFSPath else { return }
        // A pinned folder can outlive the directory it points at; catch that here rather than
        // dropping the user onto a load-failure sheet, and offer to unpin the dead entry.
        if path.backend == .local, !directoryExists(path) {
            presentMissingFavoriteEntry(path)
            return
        }
        navigate(to: path)
        focusTable()
    }

    @objc private func toggleCurrentFolderPin(_ sender: Any?) {
        var favorites = FavoritesStore.load()
        if favorites.contains(panel.path) {
            favorites.remove(path: panel.path)
        } else {
            favorites.add(FavoriteEntry(path: panel.path))
        }
        FavoritesStore.save(favorites)
    }

    // MARK: - Helpers

    private func directoryExists(_ path: VFSPath) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// A pinned folder no longer exists — tell the user and offer to unpin it in one step.
    private func presentMissingFavoriteEntry(_ path: VFSPath) {
        let alert = NSAlert()
        alert.messageText = "“\(path.lastComponent)” isn’t available"
        alert.informativeText = "This folder has been moved or deleted. Remove it from the favorites?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Keep")
        alert.enableEscapeToCancel() // ⎋ → Keep (there is no "Cancel" button here)
        let removeFromFavorites = { [weak self] in
            var favorites = FavoritesStore.load()
            if favorites.remove(path: path) { FavoritesStore.save(favorites) }
            _ = self
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { removeFromFavorites() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            removeFromFavorites()
        }
    }
}
