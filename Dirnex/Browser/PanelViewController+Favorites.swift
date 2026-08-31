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

    /// ⌘F — drop the favorites just under the path bar: one item per pinned folder (jump on
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
        if favorites.add(currentFolderPin()) {
            FavoritesStore.save(favorites)
        }
    }

    /// This pane's current folder as a pin — carrying, for a folder on a connected account, where to
    /// reconnect it.
    ///
    /// The endpoint comes from `reconnectEndpoint(for:)`, which is session restore's own reader,
    /// rather than from a second answer worked out here: a pin and a persisted tab are two things
    /// recording where the *same place* is reached from, and the pane's `CompositeBackend` is the
    /// only object that knows what a live connection was actually made with — a `VFSBackendID`
    /// carries the coordinates and not the auth method. `nil` for every local folder, which is what
    /// keeps an ordinary pin byte-identical to what earlier builds wrote.
    ///
    /// Internal rather than private so a test can ask what a pin *would* carry without writing one:
    /// `FavoritesStore` is `UserDefaults.standard`, which in a target that runs inside the app is
    /// the sidebar the person running the tests is looking at (docs/NOTES.md ▸ Testing).
    func currentFolderPin() -> FavoriteEntry {
        FavoriteEntry(path: panel.path, endpoint: reconnectEndpoint(for: tabs[activeTabIndex]))
    }

    // MARK: - Popup menu

    private func buildFavoritesMenu() -> NSMenu {
        let menu = NSMenu()
        let favorites = FavoritesStore.load()

        if favorites.entries.isEmpty {
            let empty = NSMenuItem(
                title: String(
                    localized: "No Pinned Folders",
                    comment: "Favorites menu: shown when nothing is pinned."
                ),
                action: nil,
                keyEquivalent: ""
            )
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
            title: pinned
                ? String(
                    localized: "Remove Current Folder",
                    comment: "Favorites menu: unpin the folder now open."
                )
                : String(
                    localized: "Add Current Folder",
                    comment: "Favorites menu: pin the folder now open."
                ),
            action: #selector(toggleCurrentFolderPin(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        return menu
    }

    /// One jump item, carrying its whole entry so a mid-open store change can't send the
    /// pane to the wrong (index-shifted) folder — the entry rather than the bare path because a pin
    /// on a server carries where to reconnect beside where to go. The first nine entries get a bare
    /// 1–9 accelerator, usable while the menu is open (TC's number-key jump).
    private func favoritesItem(for entry: FavoriteEntry, index: Int) -> NSMenuItem {
        let item = NSMenuItem(
            title: entry.name,
            action: #selector(jumpToFavoriteEntry(_:)),
            keyEquivalent: index < 9 ? String(index + 1) : ""
        )
        item.keyEquivalentModifierMask = []
        item.target = self
        item.representedObject = entry
        item.toolTip = entry.path.path
        let icon = NSWorkspace.shared.icon(forFile: entry.path.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    // MARK: - Actions

    @objc private func jumpToFavoriteEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? FavoriteEntry else { return }
        jumpToFavorite(entry)
    }

    /// Open a pinned folder in this pane — the one definition of what picking a favorite *does*,
    /// for the four surfaces that can pick one: this popup, a sidebar row, that row's Open item, and
    /// Go ▸ Places.
    ///
    /// A pin on a connected account needs its connection back before it can list, and the whole of
    /// arranging that is recording the endpoint on the tab: the reconnect seam is `navigate`, which
    /// asks `canListAfterReconnecting` and registers what it finds
    /// (`PanelViewController+Reconnect`). So this stays a jump rather than growing a connect flow of
    /// its own — and it connects at any refresh floor, because a click is a gesture and only the
    /// launch activation is unasked.
    ///
    /// The stored endpoint is **weighed against the path** rather than trusted on sight, through the
    /// same `TabRestorePolicy` a restored tab uses. The pin list is JSON in a defaults domain and
    /// its two fields could name different servers, which would connect to one account and then list
    /// a path belonging to another — a plausible listing under the wrong name, which is the quiet
    /// direction. A remote pin written before the endpoint existed lands there too, and fails the
    /// way it always has: `serverNotConnected`, naming the account.
    func jumpToFavorite(_ entry: FavoriteEntry) {
        // A pinned folder can outlive the directory it points at; catch that here rather than
        // dropping the user onto a load-failure sheet, and offer to unpin the dead entry.
        if entry.path.backend == .local, !directoryExists(entry.path) {
            presentMissingFavoriteEntry(entry.path)
            return
        }
        recordPendingConnection(for: entry)
        navigate(to: entry.path)
        focusTable()
    }

    /// Record what `entry` has to reconnect before it can list, where `navigate`'s seam reads it.
    ///
    /// Split out of the jump above rather than inlined, for the reason `AlertKeyCatcher.button(for:)`
    /// is split from the click it decides: the act it belongs to is a *navigation*, so a test that
    /// drove the whole gesture against a server fixture would spawn a real `sftp` at a host nobody
    /// owns. The decision is reachable with no listing, no window and no network; that the
    /// navigation follows it is one line.
    ///
    /// Returns what was recorded, so a caller — and a test — can tell "this pin needs a connection"
    /// from "it does not" without reading the tab back.
    @discardableResult
    func recordPendingConnection(for entry: FavoriteEntry) -> ServerEndpoint? {
        guard case let .connection(endpoint) = TabRestorePolicy.requirement(
            for: entry.path,
            endpoint: entry.serverEndpoint
        ) else { return nil }
        tabs[activeTabIndex].pendingConnection = endpoint
        return endpoint
    }

    @objc private func toggleCurrentFolderPin(_ sender: Any?) {
        var favorites = FavoritesStore.load()
        if favorites.contains(panel.path) {
            favorites.remove(path: panel.path)
        } else {
            favorites.add(currentFolderPin())
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
        alert.messageText = String(
            localized: "“\(path.lastComponent)” isn’t available",
            comment: "Missing-favorite alert title; %@ is the folder name."
        )
        alert.informativeText = String(
            localized: "This folder has been moved or deleted. Remove it from the favorites?",
            comment: "Missing-favorite alert body."
        )
        alert.alertStyle = .warning
        alert.addButton(
            withTitle: String(
                localized: "Remove",
                comment: "Button that unpins the missing favorite."
            )
        )
        alert.addButton(
            withTitle: String(
                localized: "Keep",
                comment: "Button that keeps the missing favorite pinned."
            )
        )
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
