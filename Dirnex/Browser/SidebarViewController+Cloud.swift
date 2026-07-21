import AppKit
import DirnexCore

/// The sidebar's **Cloud** section: iCloud Drive, plus one row per cloud provider mount under
/// `~/Library/CloudStorage` — Google Drive and whatever else is installed beside it
/// (PLAN.md §M8 "iCloud Drive row", §M10 Phase 1 "the Desktop mount"). Split out of
/// `SidebarViewController` so that file stays under its length limit, the same reason Favorites
/// and the sections logic live beside it.
///
/// Deliberately thin: unlike Favorites there is nothing to reorder, rename, or remove — these are
/// system locations, not user-owned pins — so there is no drag, no context menu, and no store. A
/// row is present or absent purely on whether the folder is on disk.
///
/// The section keeps the `icloud` identity rather than gaining a new one, so a user who had it
/// folded shut finds it still folded after the rename: `SidebarSectionCollapse` persists the raw
/// case name, and only the header's *title* changed.
extension SidebarViewController {
    /// The section's rows: iCloud Drive first — Apple's own, and the one a Mac is likeliest to
    /// have — then the provider mounts, already ordered by name.
    func cloudRows() -> [Row] {
        let iCloud = SidebarLocations.iCloudDrive().map { [Row.iCloud($0)] } ?? []
        return iCloud + CloudStorageMounts.mounts().map(Row.cloudMount)
    }

    /// Build (or reuse) the iCloud Drive cell: the `icloud` glyph and a fixed "iCloud Drive" label,
    /// with the real container path as its tooltip. No eject or delete affordance — a system row
    /// carries neither.
    func iCloudCell(for path: VFSPath) -> NSView {
        cloudCell(name: "iCloud Drive", symbolName: "icloud", tooltip: path.path)
    }

    /// Build (or reuse) a provider mount's cell — "Google Drive", or "Google Drive
    /// (someone@gmail.com)" when a second account of the same provider has to be told apart.
    ///
    /// The tooltip is the real mount path, which is the useful thing to reveal here: the label is a
    /// product name, and the path is what says *which* folder on this Mac it is.
    func cloudMountCell(for mount: CloudStorageMount) -> NSView {
        cloudCell(name: mount.name, symbolName: mount.symbolName, tooltip: mount.path.path)
    }

    /// The shared shape of a Cloud row: a template glyph, a label, no eject button.
    private func cloudCell(name: String, symbolName: String, tooltip: String) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        cell.configure(
            name: name,
            image: Self.templateSymbol(symbolName, pointSize: 15, describedAs: name),
            canEject: false,
            tooltip: tooltip
        )
        cell.onEject = nil
        return cell
    }
}
