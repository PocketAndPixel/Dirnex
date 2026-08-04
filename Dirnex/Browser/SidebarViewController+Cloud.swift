import AppKit
import DirnexCore

/// The sidebar's **Cloud** section: iCloud Drive, plus one row per cloud provider mount under
/// `~/Library/CloudStorage` — Google Drive and whatever else is installed beside it
/// (PLAN.md §M8 "iCloud Drive row", §M10 Phase 1 "the Desktop mount"). Split out of
/// `SidebarViewController` so that file stays under its length limit, the same reason Favorites
/// and the sections logic live beside it.
///
/// There is nothing here to rename or remove — these are system locations, not user-owned pins, so
/// a row is present or absent purely on whether the folder is on disk. Their **order**, though, is
/// the user's: the rows are draggable like a favorite's, and `CloudSectionOrderStore` remembers
/// where they were put. That takes an order stored beside the rows rather than in them, since the
/// rows come back from a scan every rebuild — `SidebarItemOrder` is that, and the identities it
/// keys off are chosen here (`orderIdentity`).
///
/// The section keeps the `icloud` identity rather than gaining a new one, so a user who had it
/// folded shut finds it still folded after the rename: `SidebarSectionCollapse` persists the raw
/// case name, and only the header's *title* changed.
extension SidebarViewController {
    /// The identity iCloud Drive is remembered by. A literal rather than its path: the path is
    /// `~/Library/Mobile Documents/com~apple~CloudDocs`, which carries the user's home directory
    /// into a stored order and would lose the row's position on a Mac where that differs.
    private static let iCloudOrderIdentity = "icloud"

    /// The section's rows in the user's order — or, until they have dragged anything, the natural
    /// one: iCloud Drive first (Apple's own, and the row a Mac is likeliest to have) then the
    /// provider mounts by name.
    func cloudRows() -> [Row] {
        let iCloud = SidebarLocations.iCloudDrive().map { [Row.iCloud($0)] } ?? []
        let discovered = iCloud + CloudStorageMounts.mounts().map(Row.cloudMount)
        // Every row here is a Cloud row by construction, so the fallback is unreachable rather than
        // a stand-in identity anything could be stored under.
        return CloudSectionOrderStore.load().apply(to: discovered) { Self.orderIdentity(of: $0) ?? "" }
    }

    /// How a Cloud row is named in the stored order, or `nil` for a row that is not one.
    ///
    /// A mount is keyed off its **directory name** under `~/Library/CloudStorage`, the one stable
    /// thing about it: `name` is a display string that changes the moment a second account of the
    /// same provider appears and both rows gain their account label, and keying off that would drop
    /// both rows back to the bottom of the section on the day one is added. The `mount:` prefix
    /// keeps that namespace clear of the iCloud literal.
    static func orderIdentity(of row: Row) -> String? {
        switch row {
        case .iCloud: return iCloudOrderIdentity
        case let .cloudMount(mount): return "mount:\(mount.directoryName)"
        default: return nil
        }
    }

    /// Rebuild when the shared Cloud order changes — a drag here or in another window re-sorts every
    /// open sidebar, the way a pin does.
    func observeCloudSectionOrderChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudSectionOrderChanged),
            name: CloudSectionOrderStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func cloudSectionOrderChanged() {
        rebuild()
    }

    /// Rebuild when a provider mount appears or disappears, so connecting a second Google account
    /// (or signing one out) shows up live rather than on the next launch.
    ///
    /// Volumes get this from `NSWorkspace`'s mount notifications, but a File Provider mount is not
    /// a volume and posts none — it is a directory appearing inside `~/Library/CloudStorage`, so
    /// FSEvents is what notices. The watcher is created unconditionally: on a Mac with no sync
    /// client that directory does not exist, and a stream over a missing path simply never fires,
    /// which is the same "no rows" outcome by a cheaper route than branching.
    ///
    /// Deliberately watching the *parent* rather than each mount. The parent's own children are the
    /// only thing this cares about, and watching the mounts would wake the sidebar on every file
    /// the user's Drive syncs.
    func observeCloudStorageChanges() {
        let path = CloudStorageMounts.cloudStorage()
        cloudStorageWatcher = DirectoryWatcher(path: path) { [weak self] in
            Task { @MainActor in self?.rebuild() }
        }
    }

    /// Build (or reuse) the iCloud Drive cell: the `icloud` glyph and a fixed "iCloud Drive" label,
    /// with the real container path as its tooltip. No eject or delete affordance — a system row
    /// carries neither.
    func iCloudCell(for path: VFSPath) -> NSView {
        cloudCell(
            name: String(
                localized: "iCloud Drive",
                comment: "Apple's iCloud Drive: the sidebar row, the tab title, and the path bar's root crumb."
            ),
            symbolName: "icloud",
            tooltip: path.path
        )
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
