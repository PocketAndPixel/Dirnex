import AppKit
import DirnexCore

/// The sidebar's saved-server management surface: the right-click menu (Connect / Edit… / Remove)
/// and the remove confirmation shared with the row's trailing delete button (PLAN.md §M5
/// "right-click → Connect / Edit… / Remove"). Split out of `SidebarViewController` so that file
/// stays under the length limit; `menuNeedsUpdate` (in the main file) dispatches here for a server
/// row, and connecting/editing is handed to the delegate (the window → the active pane).
extension SidebarViewController {
    // MARK: - Rendering

    /// Build (or reuse) a saved-server cell: the protocol glyph, the address as a tooltip, a
    /// spinner while this connection is being established, and the trailing delete button wired to
    /// the same confirmation the context menu's Remove uses.
    func serverCell(for connection: ServerConnection) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        cell.configure(
            name: connection.name,
            image: Self.serverIcon(for: connection.kind),
            canEject: false,
            tooltip: connection.address,
            isBusy: ServerConnectionActivity.shared.isConnecting(connection.name)
        )
        cell.onEject = nil
        cell.onDelete = { [weak self] in self?.confirmRemoveServer(named: connection.name) }
        return cell
    }

    /// A per-protocol SF Symbol so a saved server reads as remote at a glance: a globe-ish network
    /// glyph for SFTP, a connected-drive glyph for an SMB share. Template so the source list tints
    /// it with the row's text color like the other sidebar glyphs.
    private static func serverIcon(for kind: ServerKind) -> NSImage {
        let symbol = kind == .smb ? "externaldrive.connected.to.line.below" : "network"
        return templateSymbol(symbol, pointSize: 14, describedAs: "Server")
    }

    // MARK: - Right-click menu

    /// Populate `menu` with the Connect / Edit… / Remove items for `server`.
    func buildServerMenu(_ menu: NSMenu, for server: ServerConnection) {
        menu.addItem(serverMenuItem("Connect", #selector(connectServerItem(_:)), server.name))
        menu.addItem(.separator())
        menu.addItem(serverMenuItem("Edit…", #selector(editServerItem(_:)), server.name))
        menu.addItem(serverMenuItem("Remove", #selector(removeServerItem(_:)), server.name))
    }

    /// One management item, carrying the server's *name* so a mid-open store change can't act on the
    /// wrong (index-shifted) server — mirroring the saved-search popup.
    private func serverMenuItem(_ title: String, _ action: Selector, _ name: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = name
        return item
    }

    @objc private func connectServerItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let server = ServerConnectionStore.load().connection(named: name) else { return }
        delegate?.sidebar(self, didActivateServer: server)
    }

    @objc private func editServerItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let server = ServerConnectionStore.load().connection(named: name) else { return }
        delegate?.sidebar(self, didEditServer: server)
    }

    @objc private func removeServerItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        confirmRemoveServer(named: name)
    }

    /// Confirm before removing a saved server — the shared path for both the row's trailing delete
    /// button and the context-menu Remove. Removing also clears any Keychain secret filed for the
    /// connection, since nothing references it once the server is gone. No mount is disconnected —
    /// removing the bookmark shouldn't unmount a share the user is actively browsing.
    func confirmRemoveServer(named name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "This removes the saved server from the sidebar. No files are deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let commit = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            var store = ServerConnectionStore.load()
            if let server = store.connection(named: name) { Self.forgetSecret(for: server) }
            if store.remove(name: name) { ServerConnectionStore.save(store) }
            _ = self
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: commit)
        } else {
            commit(alert.runModal())
        }
    }

    /// Delete the Keychain password (if any) a removed server had filed, so we don't orphan secrets.
    private static func forgetSecret(for server: ServerConnection) {
        switch server.endpoint {
        case let .sftp(location, authentication):
            if case .password = authentication { SFTPKeychain.removePassword(for: location) }
        case let .smb(location):
            if location.username != nil { SMBKeychain.removePassword(for: location) }
        }
    }
}
