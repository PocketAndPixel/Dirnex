import AppKit
import DirnexCore

/// The directory hotlist (PLAN.md §M3 "Directory hotlist (Ctrl+D): pin, reorder, jump") —
/// Total Commander's Ctrl+D popup of pinned folders, also reachable from the Go menu and the
/// Cmd+K palette. The pane owns the actions because they're pane-relative: a jump lands in
/// *this* pane and Add pins *this* pane's folder. The shared list lives in `HotlistStore`.
///
/// This popup is now the *keyboard* face of the pin list; its visible face is the sidebar's
/// Favorites section, which since M8 renders the same `HotlistStore` (PLAN.md §M8). Reorder,
/// rename and remove live there — dragging a row, or its right-click menu — which is why the
/// organizer sheet this popup used to open no longer exists.
extension PanelViewController {
    // MARK: - Commands (dispatched to the focused pane via the responder chain)

    /// ⌃D — drop the hotlist just under the path bar: one item per pinned folder (jump on
    /// pick), then Add/Remove the current folder and Organize…
    @objc func showHotlist(_ sender: Any?) {
        let menu = buildHotlistMenu()
        // Drop the menu from the path bar's bottom edge, regardless of its flip orientation.
        let origin = NSPoint(x: 8, y: pathBar.isFlipped ? pathBar.bounds.maxY : 0)
        menu.popUp(positioning: nil, at: origin, in: pathBar)
    }

    /// "Add to Hotlist" — pin this pane's current folder (a no-op if it's already pinned).
    /// The palette-discoverable sibling of the popup's Add item.
    @objc func addToHotlist(_ sender: Any?) {
        var hotlist = HotlistStore.load()
        if hotlist.add(HotlistEntry(path: panel.path)) {
            HotlistStore.save(hotlist)
        }
    }

    // MARK: - Popup menu

    private func buildHotlistMenu() -> NSMenu {
        let menu = NSMenu()
        let hotlist = HotlistStore.load()

        if hotlist.entries.isEmpty {
            let empty = NSMenuItem(title: "No Pinned Folders", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, entry) in hotlist.entries.enumerated() {
                menu.addItem(hotlistItem(for: entry, index: index))
            }
        }

        menu.addItem(.separator())

        let pinned = hotlist.contains(panel.path)
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
    private func hotlistItem(for entry: HotlistEntry, index: Int) -> NSMenuItem {
        let item = NSMenuItem(
            title: entry.name,
            action: #selector(jumpToHotlistEntry(_:)),
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

    @objc private func jumpToHotlistEntry(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? VFSPath else { return }
        // A pinned folder can outlive the directory it points at; catch that here rather than
        // dropping the user onto a load-failure sheet, and offer to unpin the dead entry.
        if path.backend == .local, !directoryExists(path) {
            presentMissingHotlistEntry(path)
            return
        }
        navigate(to: path)
        focusTable()
    }

    @objc private func toggleCurrentFolderPin(_ sender: Any?) {
        var hotlist = HotlistStore.load()
        if hotlist.contains(panel.path) {
            hotlist.remove(path: panel.path)
        } else {
            hotlist.add(HotlistEntry(path: panel.path))
        }
        HotlistStore.save(hotlist)
    }

    // MARK: - Helpers

    private func directoryExists(_ path: VFSPath) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// A pinned folder no longer exists — tell the user and offer to unpin it in one step.
    private func presentMissingHotlistEntry(_ path: VFSPath) {
        let alert = NSAlert()
        alert.messageText = "“\(path.lastComponent)” isn’t available"
        alert.informativeText = "This folder has been moved or deleted. Remove it from the hotlist?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Keep")
        alert.enableEscapeToCancel() // ⎋ → Keep (there is no "Cancel" button here)
        let removeFromHotlist = { [weak self] in
            var hotlist = HotlistStore.load()
            if hotlist.remove(path: path) { HotlistStore.save(hotlist) }
            _ = self
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { removeFromHotlist() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            removeFromHotlist()
        }
    }
}
