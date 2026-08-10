import AppKit
import DirnexCore

/// The places/volumes strip (PLAN.md §M1 "Volumes/places strip … replaces TC's drive
/// letters"). A source-list `NSTableView` of standard folders and mounted volumes;
/// clicking a row navigates the window's active pane, and ejectable volumes carry an
/// eject button. The list rebuilds itself on mount/unmount so a plugged-in drive shows
/// up live.
///
/// It holds no pane state — enumeration lives in `DirnexCore.SidebarLocations` and the
/// actual navigation is delegated to the window controller, keeping this a thin view.
@MainActor
final class SidebarViewController: NSViewController {
    weak var delegate: SidebarViewControllerDelegate?

    /// Which sections the user has folded shut (PLAN.md §M8). Re-read from the shared store on
    /// every `rebuild`, and held here so the header cells can draw the matching triangle without
    /// each one hitting `UserDefaults`.
    var sectionCollapse = SidebarSectionCollapse()

    /// Whether the Tags section is listing every tag it knows of, or just the stock seven. Off until
    /// "All Tags…" is clicked; per window, and deliberately not persisted — it is a disclosure, not
    /// a setting. Stored here because a Swift extension cannot hold state, and the section itself
    /// lives in `SidebarViewController+Tags`.
    var showsAllTags = false
    /// The tag names the Tags section was last built from, so a scan that discovers nothing new
    /// doesn't rebuild the sidebar. Tags are re-scanned on every directory change, so this is the
    /// difference between rebuilding on a real change and rebuilding constantly.
    var renderedTagNames: Set<String> = []

    /// Watches `~/Library/CloudStorage` so a newly connected cloud account appears in the Cloud
    /// section live (`SidebarViewController+Cloud`). A stored property because an extension cannot
    /// hold one, like `renderedTagNames` above.
    var cloudStorageWatcher: DirectoryWatcher?

    /// Where each saved vault is mounted, by resolved image path — empty for every locked one.
    /// Computed once per `rebuild` (`SidebarViewController+Vaults`) rather than per row, because the
    /// answer costs a `hdiutil` spawn and every row in one pass must agree about it.
    var vaultMountPoints: [String: String] = [:]

    // A focus-preserving subclass: empty-space / header clicks don't steal keyboard focus from
    // the active file pane (which would disable the responder-chain file commands). `tableView` and
    // `rows` are `internal` (not `private`) so the companion management extensions can read the
    // clicked row (Swift `private` doesn't cross files).
    let tableView = SidebarTableView()
    private let scrollView = NSScrollView()
    var rows: [Row] = []

    // MARK: - View setup

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        registerSidebarDragTypes()

        // Right-click on a saved-search row offers Run / Rename / Delete; the menu builds its
        // items lazily from the clicked row, so it stays empty (and doesn't appear) elsewhere.
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu

        // An empty-space or header click (on the table, or in the clip area below the rows) must
        // not pull keyboard focus off the active file pane — re-focus it instead. See
        // `SidebarTableView` / `SidebarClipView`.
        let refocusActivePane: () -> Void = { [weak self] in
            guard let self else { return }
            delegate?.sidebarDidClickEmptyArea(self)
        }
        tableView.onEmptyClick = refocusActivePane
        // A header click folds its section rather than doing nothing (PLAN.md §M8); it re-focuses
        // the active pane too, which is why it doesn't simply reuse `refocusActivePane`.
        tableView.onHeaderClick = { [weak self] row in self?.toggleSection(atRow: row) }
        registerKeyboardHandlers()
        let clipView = SidebarClipView()
        clipView.onBackgroundClick = refocusActivePane
        scrollView.contentView = clipView

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // The sidebar's vibrant material runs full-height behind the transparent title bar,
        // so its rows must start below the traffic lights. Tracking the window's safe area
        // insets the first "Favorites" header clear of them automatically, with no extra
        // padding on top of that — the material is flush to the window's left/top/bottom.
        scrollView.automaticallyAdjustsContentInsets = true

        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeVolumeChanges()
        observeSectionCollapseChanges()
        observeFavoritesChanges()
        observeSavedSearchChanges()
        observeServerConnectionChanges()
        observeVaultChanges()
        observeSidebarRowActivity()
        observeTagChanges()
        observeCloudStorageChanges()
        observeCloudSectionOrderChanges()
        observePaletteChanges()
        rebuild()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Data

    /// Re-enumerate favorites and volumes and reload, keeping the visual selection on the
    /// same path if that row still exists (a drive unmounting shouldn't jump the highlight).
    /// `internal` so the Tags extension can rebuild after "All Tags…" expands the section.
    func rebuild() {
        let selectedPath = selectedRow()?.path
        sectionCollapse = SidebarSectionCollapseStore.load()

        // Section order is `SidebarSection.allCases`, and each section's header-and-items assembly
        // — including whether a folded one contributes its rows — is `append`'s, in
        // `SidebarViewController+Sections`.
        var rows: [Row] = []
        // Recents leads the sidebar, where Finder puts it — one fixed row that runs the
        // recently-used-files query into a virtual results panel (PLAN.md §M8). Always present: it
        // needs only Spotlight, which is effectively always on, so unlike iCloud it has no absent
        // state. Headerless: a section header to caption a single fixed row is pure weight, so it
        // sits bare above every collapsible section (see `SidebarSection`).
        rows.append(.recents)
        // Saved searches follow, above the standard Favorites/Volumes sections.
        append(.searches, items: SavedSearchStore.load().searches.map(Row.savedSearch), to: &rows)
        // Favorites is the user's own pin list (PLAN.md §M8) — seeded once from the standard places
        // at launch, reordered and extended by the user from here on. Alone among the sections it
        // keeps its header when empty; `append` documents why.
        append(
            .favorites,
            items: FavoritesStore.load().entries.map(Row.favorite),
            showsEmptyHeader: true,
            to: &rows
        )
        // The Cloud section, between the user's pins and the local volumes where Finder puts these:
        // iCloud Drive plus every provider mount under `~/Library/CloudStorage` (PLAN.md §M8, §M10).
        // Assembled in `SidebarViewController+Cloud`.
        append(.icloud, items: cloudRows(), to: &rows)
        // Vaults sit between the local volumes and the remote servers, because that is what one is:
        // a local volume that has to be unlocked before it exists (PLAN.md §M19). A vault's own
        // volume must never *also* appear above under Volumes: a row that moved between sections as
        // it was unlocked would be the one place the user goes to unlock it, and the duplicate
        // carries a plain eject button that detaches the image without any of the bookkeeping Lock
        // does (evicting the panes standing inside it, and dropping what `VaultPrivacy` must forget).
        //
        // `-nobrowse` used to make that impossible by itself — a hidden volume is skipped by
        // `mountedVolumeURLs(options: [.skipHiddenVolumes])` — so this was once true by construction
        // and is now a rule that has to be kept: a vault with `showsInFinder` on is browsable, and
        // is enumerated here exactly like any other mount (verified). Hence the mount points are
        // resolved *before* the Volumes section rather than after it.
        let vaults = VaultStore.load().vaults
        vaultMountPoints = Self.mountPoints(of: vaults)
        append(
            .volumes,
            items: SidebarLocations.hidingVaults(
                in: SidebarLocations.volumes(),
                mountedAt: Set(vaultMountPoints.values)
            ).map(Row.volume),
            to: &rows
        )
        append(.vaults, items: vaults.map(Row.vault), to: &rows)
        // Saved servers, grouped with the local volumes as the "places you browse"
        // (PLAN.md §M5 "a Servers sidebar section mirroring Searches").
        append(.servers, items: ServerConnectionStore.load().connections.map(Row.server), to: &rows)
        // Tags close the collapsible sections, where Finder puts them, and only when View ▸ Show
        // Tags is on.
        append(.tags, items: tagRows(), to: &rows)
        // The Trash is the very last row, where the Dock puts it — one fixed headerless row that
        // opens every volume's trash as one merged listing. Always present: every Mac has one, and
        // whether it can be read is the pane's answer to give, not a reason to hide the row.
        //
        // Having no header of its own, it would otherwise sit flush against the section above and
        // read as a member of it — with Tags shown, as an eighth tag color. The spacer restores the
        // separation a header used to provide, at exactly the gap AppKit itself puts above a section
        // (see `heightOfRow`).
        rows.append(.spacer)
        rows.append(.trash)
        self.rows = rows
        tableView.reloadData()

        if let selectedPath, let index = rows.firstIndex(where: { $0.path == selectedPath }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func selectedRow() -> Row? {
        let index = tableView.selectedRow
        return rows.indices.contains(index) ? rows[index] : nil
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        // Workspace volume notifications are delivered on the main thread, so the
        // main-actor selector is safe; teardown is a single removeObserver in deinit.
        for name in names {
            center.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
    }

    @objc private func volumesChanged() {
        rebuild()
    }

    /// Rebuild when the shared pin list changes — a pin from ⌃D, a rename or removal here, or the
    /// same in another window, shows up live in the Favorites section (PLAN.md §M8).
    private func observeFavoritesChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(favoritesChanged),
            name: FavoritesStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func favoritesChanged() {
        rebuild()
    }

    /// Rebuild when the shared saved-search list changes — a Save/Rename/Delete here or in
    /// another window shows up live in the Searches section.
    private func observeSavedSearchChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(savedSearchesChanged),
            name: SavedSearchStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func savedSearchesChanged() {
        rebuild()
    }

    /// Rebuild when the shared server list changes — a Save/Edit/Remove here or in another window
    /// shows up live in the Servers section.
    private func observeServerConnectionChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(serverConnectionsChanged),
            name: ServerConnectionStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func serverConnectionsChanged() {
        rebuild()
    }

    /// Refresh a row's spinner when slow work starts or finishes — in this window or another.
    /// Unlike a store change this needs no full rebuild (the rows themselves are unchanged), so it
    /// reloads only the rows that can carry one in place, leaving the current selection untouched.
    private func observeSidebarRowActivity() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(serverActivityChanged),
            name: SidebarRowActivity.didChangeNotification,
            object: nil
        )
    }

    @objc private func serverActivityChanged() {
        let serverRows = rows.indices.filter { rows[$0].server != nil || rows[$0].vault != nil }
        guard !serverRows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(serverRows),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        activate(rowAt: tableView.clickedRow)
    }

    /// Run the row's action — navigate to a place/volume, run a saved search or tag query, connect a
    /// server, or expand the Tags section. Shared by a mouse click (`rowClicked`) and a keyboard
    /// Return/Space (`SidebarViewController+Keyboard`), so both surfaces dispatch a row exactly one
    /// way. `internal`, not `private`: the keyboard companion file calls it, and Swift `private`
    /// doesn't cross files.
    func activate(rowAt index: Int) {
        guard rows.indices.contains(index) else { return }
        if case .recents = rows[index] {
            delegate?.sidebarDidActivateRecents(self)
        } else if case .trash = rows[index] {
            delegate?.sidebarDidActivateTrash(self)
        } else if let savedSearch = rows[index].savedSearch {
            delegate?.sidebar(self, didActivateSavedSearch: savedSearch)
        } else if let server = rows[index].server {
            delegate?.sidebar(self, didActivateServer: server)
        } else if let vault = rows[index].vault {
            delegate?.sidebar(self, didActivateVault: vault)
        } else if let tag = rows[index].tag {
            delegate?.sidebar(self, didActivateTag: tag)
        } else if case .allTags = rows[index] {
            expandAllTags()
        } else if case .iCloud = rows[index] {
            // Dispatched rather than navigated even though the row *has* a path: what it opens is
            // the merge of that container with the app libraries beside it, which is a listing to
            // assemble rather than a directory to list (PLAN.md §M9).
            delegate?.sidebarDidActivateICloud(self)
        } else if let path = rows[index].path {
            delegate?.sidebar(self, didActivate: path)
        }
    }
}

// MARK: - NSTableViewDataSource

extension SidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

// MARK: - NSTableViewDelegate

extension SidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows[row].isHeader
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Headers are keyboard-selectable so arrow navigation can land on one and ←/→/Return fold it
        // (PLAN.md §M8). The mouse never selects a header: `SidebarTableView.mouseDown` intercepts a
        // header click and returns before `super`, so a click still folds rather than selects.
        //
        // The spacer is the one row that isn't: it is blank padding, so ↑/↓ steps straight over it
        // (AppKit skips unselectable rows) and a click on it is treated as a click on empty space.
        if case .spacer = rows[row] { return false }
        return true
    }

    /// Row heights.
    ///
    /// Implementing this at all means owning **every** row's height — AppKit's automatic
    /// `rowSizeStyle = .default` sizing stops applying the moment the delegate answers. So the two
    /// real kinds return the values AppKit itself was using, probed on a `.sourceList` table
    /// configured exactly like this one: 19 pt for a group row, and `rowHeight` — which AppKit sets
    /// to 32 for `.default` — for an item. Verified byte-identical against the stock layout, row
    /// origins included, so nothing but the spacer moved.
    ///
    /// The spacer's 13 pt is not a taste value either: it is the gap AppKit inserts above every
    /// section header (measured — a header following an item row starts 13 pt below it), so the
    /// space above Trash matches the space above every other group in the list.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: 19
        case .spacer: 13
        default: tableView.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(section):
            let cell = reuse(SidebarHeaderView.identifier) as? SidebarHeaderView
            let header = cell ?? SidebarHeaderView()
            header.configure(
                title: LocalizedCatalog.title(for: section),
                isCollapsed: sectionCollapse.isCollapsed(section)
            )
            return header
        case .recents:
            return recentsCell()
        case .trash:
            return trashCell()
        case .spacer:
            // Nothing to draw: the row is its own height and no more.
            return nil
        case let .favorite(entry):
            return favoriteCell(for: entry)
        case let .iCloud(path):
            return iCloudCell(for: path)
        case let .cloudMount(mount):
            return cloudMountCell(for: mount)
        case let .volume(volume):
            return volumeCell(for: volume)
        case let .savedSearch(search):
            return savedSearchCell(for: search)
        case let .server(connection):
            return serverCell(for: connection)
        case let .vault(location):
            return vaultCell(for: location)
        case let .tag(tag):
            return tagCell(for: tag)
        case .allTags:
            return allTagsCell()
        }
    }

    /// Every sidebar glyph is a template SF Symbol, so the source list tints it with the row's
    /// text color — and turns it white on the selected row — matching the label beside it.
    /// `internal`, not `private`: the favorites companion file renders its own glyphs through this,
    /// and Swift `private` does not cross files.
    static func templateSymbol(
        _ name: String,
        pointSize: CGFloat,
        describedAs description: String? = nil
    ) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage()
    }

    func reuse(_ identifier: NSUserInterfaceItemIdentifier) -> NSView? {
        tableView.makeView(withIdentifier: identifier, owner: self)
    }
}

// MARK: - Right-click context menu

extension SidebarViewController: NSMenuDelegate {
    /// Build the right-click menu lazily from the clicked row, dispatching to the Trash,
    /// saved-search, server or tag builder (in companion files). Any other row — a header, place, or
    /// volume — leaves the menu empty, so AppKit shows nothing.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        if case .trash = rows[row] {
            buildTrashMenu(menu)
        } else if let entry = rows[row].favorite {
            buildFavoriteMenu(menu, for: entry)
        } else if let search = rows[row].savedSearch {
            buildSavedSearchMenu(menu, for: search)
        } else if let server = rows[row].server {
            buildServerMenu(menu, for: server)
        } else if let vault = rows[row].vault {
            buildVaultMenu(menu, for: vault)
        } else if let tag = rows[row].tag {
            buildTagMenu(menu, for: tag)
        }
    }
}
