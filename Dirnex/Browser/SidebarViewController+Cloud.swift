import AppKit
import DirnexCore

/// The sidebar's **Cloud** section: iCloud Drive, plus one row per cloud provider mount under
/// `~/Library/CloudStorage` — Google Drive and whatever else is installed beside it
/// (PLAN.md §M8 "iCloud Drive row", §M10 Phase 1 "the Desktop mount"). Split out of
/// `SidebarViewController` so that file stays under its length limit, the same reason Favorites
/// and the sections logic live beside it.
///
/// There is nothing here to remove — these are system locations, not user-owned pins, so a row is
/// present or absent purely on whether the folder is on disk. Their **order** and their **names**,
/// though, are the user's: the rows are draggable like a favorite's, and can be renamed
/// (`SidebarViewController+CloudRename`). Both take a store beside the rows rather than in them,
/// since the rows come back from a scan every rebuild — `SidebarItemOrder` and `SidebarItemNames`
/// are those, keyed by the identities `CloudPlaceIdentity` defines once for the two.
///
/// The section keeps the `icloud` identity rather than gaining a new one, so a user who had it
/// folded shut finds it still folded after the rename: `SidebarSectionCollapse` persists the raw
/// case name, and only the header's *title* changed.
extension SidebarViewController {
    /// The section's places in the user's order — or, until they have dragged anything, the natural
    /// one: iCloud Drive and then Photos (Apple's own, and the rows a Mac is likeliest to have), then
    /// the provider mounts by name.
    ///
    /// The order is applied *here* rather than in `SidebarPlaces`, which takes this list already
    /// sorted: it is the user's arrangement, held in a `UserDefaults` store, and the core assembly
    /// reads no stores at all (PLAN.md §M20).
    func cloudPlaces() -> [SidebarPlace] {
        let iCloud = SidebarLocations.iCloudDrive().map { [SidebarPlace.iCloudDrive($0)] } ?? []
        let discovered = iCloud + [SidebarPlace.photos] + CloudStorageMounts.mounts().map(
            SidebarPlace.cloudMount
        )
        // Everything here is a Cloud place by construction, so the fallback is unreachable rather
        // than a stand-in identity anything could be stored under.
        return CloudSectionOrderStore.load().apply(to: discovered) { CloudPlaceIdentity.of($0) ?? "" }
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

    /// Rebuild when a Cloud row is renamed — here, from another window, or from the pane's own
    /// Places menu, which shares the store. Scoped to the app's own domain so a test writing to a
    /// scratch one leaves the sidebar alone (docs/NOTES.md ▸ Testing).
    func observeCloudPlaceNameChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudPlaceNamesChanged),
            name: CloudPlaceNameStore.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    @objc private func cloudPlaceNamesChanged() {
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

    /// Build (or reuse) the iCloud Drive cell: the `icloud` glyph and "iCloud Drive" — or what the
    /// user renamed it to — with the real container path as its tooltip. No eject or delete
    /// affordance — a system row carries neither.
    func iCloudCell(for path: VFSPath) -> NSView {
        cloudCell(
            name: SidebarPlacePresentation.title(for: .iCloudDrive(path)),
            symbolName: SidebarPlacePresentation.symbolName(for: .iCloudDrive(path)) ?? "icloud",
            tooltip: path.path
        )
    }

    /// Build (or reuse) the Photos library's cell (PLAN.md §M28). The tooltip is the library's own
    /// name: where the library's file lives is PhotoKit's business and need not be the default, so
    /// there is no path worth revealing, and guessing one would name a file nobody is browsing. It
    /// repeats the row's label until the user renames the row, and then says what the row is.
    func photosCell() -> NSView {
        cloudCell(
            name: SidebarPlacePresentation.title(for: .photos),
            symbolName: PhotosPresentation.symbolName,
            tooltip: PhotosPresentation.libraryTitle
        )
    }

    /// Build (or reuse) a provider mount's cell — "Google Drive", or "someone@gmail.com — Google
    /// Drive" when a second account of the same provider has to be told apart, or whatever the user
    /// renamed the row to.
    ///
    /// The tooltip is the real mount path, which is the useful thing to reveal here: the label is a
    /// product name or a nickname, and the path is what says *which* folder on this Mac it is.
    func cloudMountCell(for mount: CloudStorageMount) -> NSView {
        cloudCell(
            name: SidebarPlacePresentation.title(for: .cloudMount(mount)),
            symbolName: mount.symbolName,
            tooltip: mount.path.path
        )
    }

    /// The shared shape of a Cloud row: a template glyph, a label, no eject button. The glyph is
    /// described by the label, so VoiceOver reads a renamed row by its new name.
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
