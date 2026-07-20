import AppKit
import DirnexCore

/// The sidebar's Recents row (PLAN.md §M8 "Recents row"): one fixed row, first in the sidebar the
/// way Finder places it, that runs the recently-used-files query and shows the hits in a virtual
/// results panel. Split out of `SidebarViewController` so that file stays under its length limit,
/// the same reason iCloud, Favorites and the sections logic live beside it.
///
/// Deliberately thin, like the iCloud row: it dispatches a query rather than pointing at a place, so
/// there is nothing to reorder, rename, or remove — no drag, no context menu, and no store. The
/// activation itself lives in `SidebarViewController.activate(rowAt:)`, routed to the window
/// controller, which reuses the search machinery.
extension SidebarViewController {
    /// Build (or reuse) the Recents cell: the `clock` glyph Finder uses and a fixed "Recents" label.
    /// No eject or delete affordance — like iCloud it is a system row, not a user-owned pin.
    func recentsCell() -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        cell.configure(
            name: "Recents",
            image: Self.templateSymbol("clock", pointSize: 15, describedAs: "Recents"),
            canEject: false,
            tooltip: "Recently used files"
        )
        cell.onEject = nil
        return cell
    }
}
