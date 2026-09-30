import AppKit
import DirnexCore

/// Renaming a sidebar **Cloud** row — iCloud Drive, Photos, or a provider mount — from its
/// right-click menu, or with F2 on the selected row.
///
/// **It renames the row, not the place.** A mount's folder belongs to its sync client, which would
/// put a renamed one back or lose track of it, and neither iCloud Drive nor the Photos library has a
/// name a file manager may change. What the rows were already showing is a name Dirnex made up —
/// `GoogleDrive-someone@gmail.com` drawn as "someone@gmail.com — Google Drive", which truncates in
/// any sidebar narrow enough to be useful — so the rename replaces *that*, wherever Dirnex draws it:
/// the row, the Go ▸ Places item, the path bar's root crumb and a tab parked at the place
/// (`CloudPlaceTitle`).
///
/// Unlike a vault's rename there is nothing to unlock and nothing to fail, so the flow is one sheet.
/// An emptied field puts the original name back, and so does the menu's own item for it, which is
/// only offered once there is something to restore.
extension SidebarViewController {
    /// The Cloud place under the keyboard cursor, if this row is one.
    var selectedCloudPlace: SidebarPlace? {
        let row = tableView.selectedRow
        guard rows.indices.contains(row), let place = rows[row].place,
              CloudPlaceIdentity.of(place) != nil else { return nil }
        return place
    }

    // MARK: - Right-click menu

    /// Populate `menu` with Open, Rename… and, for a row the user has renamed, Restore Original
    /// Name — the shape the favorite and Trash menus already have, Open first.
    func buildCloudPlaceMenu(
        _ menu: NSMenu,
        for place: SidebarPlace,
        names: SidebarItemNames = CloudPlaceNameStore.load()
    ) {
        guard let identity = CloudPlaceIdentity.of(place) else { return }
        menu.addItem(cloudPlaceMenuItem(
            String(
                localized: "Open",
                comment: "Sidebar context-menu item on iCloud Drive, Photos or a cloud-provider row: open it."
            ),
            #selector(openCloudPlaceItem(_:)),
            identity
        ))
        menu.addItem(.separator())
        menu.addItem(cloudPlaceMenuItem(
            String(
                localized: "Rename…",
                // Verbatim at every sidebar site that keys this string — see the note in
                // `SidebarViewController+Vaults`.
                comment: "Sidebar context-menu item: the Rename verb."
            ),
            #selector(renameCloudPlaceItem(_:)),
            identity
        ))
        guard names.name(for: identity) != nil else { return }
        menu.addItem(cloudPlaceMenuItem(
            String(
                localized: "Restore Original Name",
                comment: """
                Sidebar context-menu item on a renamed iCloud Drive, Photos or cloud-provider row: \
                show the name Dirnex gives it again.
                """
            ),
            #selector(restoreCloudPlaceNameItem(_:)),
            identity
        ))
    }

    /// One item, carrying the place's *identity* rather than a row index — the rows are rebuilt
    /// whenever a mount comes or goes, and an index would then act on a different place.
    private func cloudPlaceMenuItem(
        _ title: String,
        _ action: Selector,
        _ identity: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = identity
        return item
    }

    /// The Cloud place on screen with `identity`, found among the rows the sidebar already holds.
    /// Never a rescan: that reads inside every mount, and a File Provider mount's `readdir` can
    /// reach the network.
    private func cloudPlace(identity: String) -> SidebarPlace? {
        rows.lazy.compactMap(\.place).first { CloudPlaceIdentity.of($0) == identity }
    }

    /// Open goes through `activate(_:)`, the funnel a click on the row uses, because two of the
    /// three places are not a path to navigate to: iCloud Drive assembles a merged listing and
    /// Photos asks macOS for library access on first use.
    @objc private func openCloudPlaceItem(_ sender: NSMenuItem) {
        guard let identity = sender.representedObject as? String,
              let place = cloudPlace(identity: identity) else { return }
        activate(place)
    }

    @objc private func renameCloudPlaceItem(_ sender: NSMenuItem) {
        guard let identity = sender.representedObject as? String,
              let place = cloudPlace(identity: identity) else { return }
        renameCloudPlace(place)
    }

    /// No confirmation: what is lost is a label the user typed, and typing it again is the whole
    /// cost — the same reasoning that lets a favorite be unpinned without a sheet.
    @objc private func restoreCloudPlaceNameItem(_ sender: NSMenuItem) {
        guard let identity = sender.representedObject as? String else { return }
        var names = CloudPlaceNameStore.load()
        if names.reset(identity) { CloudPlaceNameStore.save(names, to: .standard) }
    }

    // MARK: - Rename

    /// Ask for a name for `place` and store it.
    func renameCloudPlace(_ place: SidebarPlace) {
        guard let identity = CloudPlaceIdentity.of(place),
              let defaultName = CloudPlaceTitle.defaultTitle(for: place),
              let current = CloudPlaceTitle.title(for: place) else { return }
        // The prompt is a sheet, so it is awaited rather than run inline.
        Task { @MainActor in
            guard let typed = await promptForCloudPlaceName(
                current: current,
                defaultName: defaultName
            ) else { return }
            var names = CloudPlaceNameStore.load()
            guard names.rename(identity, to: typed, defaultName: defaultName) else { return }
            CloudPlaceNameStore.save(names, to: .standard)
        }
    }

    /// Ask for a name, prefilled with the current one. `nil` on Cancel; an empty string is an answer
    /// — "use the original name" — which the body says and the placeholder shows.
    private func promptForCloudPlaceName(current: String, defaultName: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Rename “\(current)”",
            comment: """
            Title of the dialog that renames an iCloud Drive, Photos or cloud-provider row in the \
            sidebar; %@ is the row's current name.
            """
        )
        alert.informativeText = String(
            localized: """
            Dirnex uses this name in the sidebar, in tabs and in the path bar. Nothing is renamed on \
            your Mac or in the cloud. Leave the field empty to go back to “\(defaultName)”.
            """,
            comment: """
            Body of the dialog that renames a cloud row in the sidebar; %@ is the name Dirnex gives \
            the row when the user has not renamed it.
            """
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
        field.placeholderString = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = await alert.runSheet(over: view.window) { field.selectText(nil) }
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
