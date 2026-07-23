import AppKit
import DirnexCore

/// The sidebar's Trash row (PLAN.md §M8 "Trash row"): one fixed row at the very bottom of the list —
/// where the Dock puts it — that opens every volume's trash as one merged listing
/// (`PanelViewController+Trash`). Split out of `SidebarViewController` so that file stays under its
/// length limit, the same reason Recents, iCloud and Favorites live beside it.
///
/// Thin like the other system rows: it dispatches an action rather than pointing at a place, so
/// there is no drag and no store. Deliberately **always present**, unlike the iCloud row that hides
/// when its container is absent — every Mac has a Trash, and the reasons this one might list nothing
/// (no Full Disk Access, or genuinely empty) are answers the pane gives when the row is clicked, not
/// reasons to hide the row and leave the user hunting for it.
///
/// It is the one system row with a **context menu**: Empty Trash is where a Mac user reaches for it
/// (the Dock's Trash has exactly this menu), and "select all inside the Trash, then Shift+F8" is a
/// worse answer for the most routine thing anyone does to a Trash. The safety that the in-pane route
/// gets for free — you are destroying items you can see listed — is bought back here by naming the
/// count in the confirmation, so the sheet is never a blind "erase everything".
extension SidebarViewController {
    /// Build (or reuse) the Trash cell: the `trash` glyph Finder and the Dock both use, and a fixed
    /// label. No eject or delete affordance — a system row carries neither.
    func trashCell() -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        let trash = String(localized: "Trash", comment: "Sidebar row and section for deleted items.")
        cell.configure(
            name: trash,
            image: Self.templateSymbol("trash", pointSize: 15, describedAs: trash),
            canEject: false,
            tooltip: String(
                localized: "Deleted items, from every volume",
                comment: "Tooltip on the sidebar's Trash row."
            )
        )
        cell.onEject = nil
        return cell
    }

    /// The Trash row's right-click menu: open it, or empty it. Both are dispatched to the window
    /// controller like a row click, so emptying runs against the same merged set of trash
    /// directories the row browses rather than a second idea of where the Trash is.
    func buildTrashMenu(_ menu: NSMenu) {
        menu.addItem(trashMenuItem(
            String(localized: "Open", comment: "Trash context-menu item: browse the Trash."),
            #selector(openTrashItem(_:))
        ))
        menu.addItem(.separator())
        // The ellipsis is a promise: this asks before it destroys anything.
        menu.addItem(trashMenuItem(
            String(
                localized: "Empty Trash…",
                comment: "Trash context-menu item: permanently erase everything."
            ),
            #selector(emptyTrashItem(_:))
        ))
    }

    /// One menu item. Unlike the favorites menu's, these carry no `representedObject` — there is
    /// exactly one Trash, so there is no identity for a mid-open change to invalidate.
    private func trashMenuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openTrashItem(_ sender: NSMenuItem) {
        delegate?.sidebarDidActivateTrash(self)
    }

    @objc private func emptyTrashItem(_ sender: NSMenuItem) {
        delegate?.sidebarDidRequestEmptyTrash(self)
    }
}
