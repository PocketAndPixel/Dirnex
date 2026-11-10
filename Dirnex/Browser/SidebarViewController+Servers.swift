import AppKit
import DirnexCore

/// The sidebar's saved-server management surface: the right-click menu (Connect / Edit… / Remove)
/// and its remove confirmation (PLAN.md §M5 "right-click → Connect / Edit… / Remove"). Split out of
/// `SidebarViewController` so that file stays under the length limit; `menuNeedsUpdate` (in the main
/// file) dispatches here for a server row, and connecting/editing is handed to the delegate (the
/// window → the active pane).
extension SidebarViewController {
    // MARK: - Rendering

    /// Build (or reuse) a saved-server cell: the protocol glyph, the address and any space left as a
    /// tooltip, and a spinner while this connection is being established. Removal is a
    /// right-click-menu action, not a per-row button.
    func serverCell(for connection: ServerConnection) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        cell.configure(
            name: SidebarPlacePresentation.title(for: .server(connection)),
            image: Self.serverIcon(for: connection),
            canEject: false,
            tooltip: Self.serverTooltip(for: connection),
            isBusy: SidebarRowActivity.shared.isWorking(connection.name)
        )
        cell.onEject = nil
        return cell
    }

    /// The server's address, and under it the space it last said it has left, when it has said
    /// (PLAN.md §M38 Slice 7). Only a WebDAV server is asked, and only one that reports RFC 4331's
    /// quota answers, which of those measured is Nextcloud and not Apache (``WebDAVQuota``).
    ///
    /// "Available" with no total, where a volume's tooltip says "of": the reason is
    /// ``WebDAVProcessArguments/quotaPropfindBody``'s, and the choice was Oleg's (2026-11-10).
    static func serverTooltip(
        for connection: ServerConnection,
        quotas: ServerQuotaBook = .shared
    ) -> String {
        guard case let .webdav(location, _, _) = connection.endpoint,
              let quota = quotas.quota(for: location)
        else { return connection.address }
        let space = String(
            localized: "\(FileFormatting.byteString(quota.availableBytes)) available",
            comment: """
            Second line of a saved server's sidebar tooltip, under its address: the space the \
            server says is left to the account. %@ is a size such as “98.9 MB”.
            """
        )
        return connection.address + "\n" + space
    }

    /// Redraw the server rows' tooltips when a server's answer about its space changes, the way a
    /// spinner is redrawn: in place, the rows themselves unchanged.
    func observeServerQuota() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(serverQuotaChanged),
            name: ServerQuotaBook.didChangeNotification,
            object: ServerQuotaBook.shared
        )
    }

    @objc private func serverQuotaChanged() {
        let servers = rows.indices.filter { rows[$0].server != nil }
        guard !servers.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(servers), columnIndexes: IndexSet(integer: 0))
    }

    /// A per-protocol SF Symbol so a saved server reads as remote at a glance: a globe-ish network
    /// glyph for SFTP, a connected-drive glyph for an SMB share, and an up/down transfer glyph for
    /// FTP — the protocol's own name, and unmistakable against the other two at 14 pt.
    /// Template so the source list tints it with the row's text color like the other sidebar glyphs.
    private static func serverIcon(for connection: ServerConnection) -> NSImage {
        let symbol = SidebarPlacePresentation.symbolName(for: .server(connection)) ?? "network"
        return templateSymbol(symbol, pointSize: 14, describedAs: String(
            localized: "Server",
            comment: "Accessibility label for a saved-server sidebar row's glyph."
        ))
    }

    // MARK: - Right-click menu

    /// Populate `menu` with the Connect / Edit… / Remove items for `server`.
    func buildServerMenu(_ menu: NSMenu, for server: ServerConnection) {
        menu.addItem(serverMenuItem(
            String(
                localized: "Connect",
                comment: "Saved-server context-menu item: open the connection."
            ),
            #selector(connectServerItem(_:)),
            server.name
        ))
        menu.addItem(.separator())
        menu.addItem(serverMenuItem(
            String(
                localized: "Edit…",
                comment: "Saved-server context-menu item: edit the connection."
            ),
            #selector(editServerItem(_:)),
            server.name
        ))
        menu.addItem(serverMenuItem(
            String(
                localized: "Remove",
                comment: "Saved-server context-menu item: remove the bookmark."
            ),
            #selector(removeServerItem(_:)),
            server.name
        ))
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
        delegate?.sidebar(self, didActivateServer: server, inNewTab: false)
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

    /// Confirm before removing a saved server — the context-menu Remove's path. Removing also clears
    /// any Keychain secret filed for the
    /// connection, since nothing references it once the server is gone. No mount is disconnected —
    /// removing the bookmark shouldn't unmount a share the user is actively browsing.
    func confirmRemoveServer(named name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Remove “\(name)”?",
            comment: "Saved-server remove confirmation title; %@ is the server's name."
        )
        alert.informativeText = String(
            localized: "This removes the saved server from the sidebar. No files are deleted.",
            comment: "Body of the remove-saved-server confirmation."
        )
        alert.addButton(withTitle: String(
            localized: "Remove",
            comment: "Confirm button that removes a saved server."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel()

        let commit = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            var store = ServerConnectionStore.load()
            let server = store.connection(named: name)
            if store.remove(name: name) { ServerConnectionStore.save(store) }
            if let server { Self.forgetSecret(for: server, keptBy: store.connections) }
            _ = self
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: commit)
        } else {
            commit(alert.runModal())
        }
    }

    /// Delete the Keychain password (if any) a removed server had filed, so we don't orphan secrets.
    /// `remaining` is the saved servers left after the removal, which a WebDAV password can still
    /// belong to.
    private static func forgetSecret(
        for server: ServerConnection,
        keptBy remaining: [ServerConnection]
    ) {
        switch server.endpoint {
        case let .sftp(location, authentication):
            if case .password = authentication { SecretKeychain.removePassword(for: location) }
        case let .ftp(location, authentication, _, _):
            if case .password = authentication { SecretKeychain.removePassword(for: location) }
        case let .smb(location):
            if location.username != nil { SecretKeychain.removePassword(for: location) }
        case let .s3(location):
            // Unconditional: a saved bucket always has a secret filed, since SigV4 is the only way
            // in and there is no anonymous variant to skip.
            SecretKeychain.removePassword(for: location)
        case let .s3Account(account):
            // The account's own item, which is a bucket's key without the trailing `/<bucket>` —
            // so removing a saved account leaves the buckets reached from it able to reconnect,
            // which is right: each of those was a connection the user made on its own.
            SecretKeychain.removePassword(for: account)
        case let .webdav(location, _, _):
            // Filed without the root (`WebDAVLocation.keychainAccount`), so another saved root on
            // the same account reads the same item, and removing one row must not leave the other
            // asking for a password it was saved with.
            let shared = remaining.contains { other in
                guard case let .webdav(otherLocation, _, _) = other.endpoint else { return false }
                return otherLocation.keychainAccount == location.keychainAccount
            }
            if location.hasCredentials, !shared { SecretKeychain.removePassword(for: location) }
        }
    }
}
