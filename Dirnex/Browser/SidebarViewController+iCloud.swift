import AppKit
import DirnexCore

/// The sidebar's iCloud Drive section (PLAN.md §M8 "iCloud Drive row"): one fixed row that
/// navigates the active pane to `~/Library/Mobile Documents/com~apple~CloudDocs`, when that
/// container exists (`SidebarLocations.iCloudDrive()` decides). Split out of `SidebarViewController`
/// so that file stays under its length limit, the same reason Favorites and the sections logic live
/// beside it.
///
/// Deliberately thin: unlike Favorites there is nothing to reorder, rename, or remove — it is a
/// system location, not a user-owned pin — so there is no drag, no context menu, and no store. The
/// row is present or absent purely on whether iCloud Drive is turned on.
extension SidebarViewController {
    /// Build (or reuse) the iCloud Drive cell: the `icloud` glyph and a fixed "iCloud Drive" label,
    /// with the real container path as its tooltip. No eject or delete affordance — a system row
    /// carries neither.
    func iCloudCell(for path: VFSPath) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        cell.configure(
            name: "iCloud Drive",
            image: Self.templateSymbol("icloud", pointSize: 15, describedAs: "iCloud Drive"),
            canEject: false,
            tooltip: path.path
        )
        cell.onEject = nil
        return cell
    }
}
