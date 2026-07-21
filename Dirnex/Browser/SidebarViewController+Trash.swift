import AppKit
import DirnexCore

/// The sidebar's Trash row (PLAN.md §M8 "Trash row"): one fixed row at the very bottom of the list —
/// where the Dock puts it — that opens every volume's trash as one merged listing
/// (`PanelViewController+Trash`). Split out of `SidebarViewController` so that file stays under its
/// length limit, the same reason Recents, iCloud and Favorites live beside it.
///
/// Thin like the other system rows: it dispatches an action rather than pointing at a place, so
/// there is no drag, no context menu and no store. Deliberately **always present**, unlike the
/// iCloud row that hides when its container is absent — every Mac has a Trash, and the reasons this
/// one might list nothing (no Full Disk Access, or genuinely empty) are answers the pane gives when
/// the row is clicked, not reasons to hide the row and leave the user hunting for it.
///
/// There is no "Empty Trash" command here on purpose. Emptying is `⌘A` then `F8` *inside* the
/// Trash — a confirmed permanent delete of things the user can see listed — rather than a one-click
/// irreversible destroy of contents they cannot.
extension SidebarViewController {
    /// Build (or reuse) the Trash cell: the `trash` glyph Finder and the Dock both use, and a fixed
    /// label. No eject or delete affordance — a system row carries neither.
    func trashCell() -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        cell.configure(
            name: "Trash",
            image: Self.templateSymbol("trash", pointSize: 15, describedAs: "Trash"),
            canEject: false,
            tooltip: "Deleted items, from every volume"
        )
        cell.onEject = nil
        return cell
    }
}
