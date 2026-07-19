import AppKit
import DirnexCore

/// Receives a sidebar row click so the window can point the active pane at it.
@MainActor
protocol SidebarViewControllerDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didActivate path: VFSPath)
    /// A saved-search row was picked — re-run its query in the active pane and show the hits in
    /// a virtual results panel (PLAN.md §M4 "Saved searches … in the places strip").
    func sidebar(_ sidebar: SidebarViewController, didActivateSavedSearch savedSearch: SavedSearch)
    /// A saved-server row was picked — connect (SFTP) or mount (SMB) it and browse it in the active
    /// pane (PLAN.md §M5 "click → connect/mount + navigate").
    func sidebar(_ sidebar: SidebarViewController, didActivateServer server: ServerConnection)
    /// A saved-server's "Edit…" was chosen — re-open the connect prompt prefilled from it.
    func sidebar(_ sidebar: SidebarViewController, didEditServer server: ServerConnection)
    /// A tag row was picked — search for the files carrying it and show the hits in a virtual
    /// results panel (PLAN.md §M6 "Finder tags: … filter chips in search"), like Finder's own
    /// sidebar tags.
    func sidebar(_ sidebar: SidebarViewController, didActivateTag tag: FinderTag)
    /// A click landed on the sidebar's empty space or a non-selectable header. Keep keyboard
    /// focus on the active file pane rather than letting the source list steal it — the pane's
    /// file commands (F5/F6/F8) are dispatched through the responder chain and go dead the moment
    /// no pane is first responder.
    func sidebarDidClickEmptyArea(_ sidebar: SidebarViewController)
}

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
    /// A rendered sidebar row: a section header or a navigable destination. `internal` (not
    /// `private`) so the saved-search and server management extensions in companion files can read
    /// the clicked row.
    enum Row {
        case header(String)
        case place(FavoritePlace)
        case volume(MountedVolume)
        case savedSearch(SavedSearch)
        case server(ServerConnection)
        case tag(FinderTag)
        /// The "All Tags…" row: reveals the tags found by browsing, past the stock seven.
        case allTags

        var isHeader: Bool {
            if case .header = self { return true }
            return false
        }

        /// The path a click navigates to, when the row is a real location. `nil` for headers, saved
        /// searches, servers, and tags — a saved search runs a query, a server connects/mounts, and
        /// a tag searches, so each is dispatched through its own delegate call instead of pointing
        /// at a directory.
        var path: VFSPath? {
            switch self {
            case .header, .savedSearch, .server, .tag, .allTags: return nil
            case let .place(place): return place.path
            case let .volume(volume): return volume.path
            }
        }

        var savedSearch: SavedSearch? {
            if case let .savedSearch(search) = self { return search }
            return nil
        }

        var server: ServerConnection? {
            if case let .server(connection) = self { return connection }
            return nil
        }

        var tag: FinderTag? {
            if case let .tag(tag) = self { return tag }
            return nil
        }
    }

    weak var delegate: SidebarViewControllerDelegate?

    /// Whether the Tags section is listing every tag it knows of, or just the stock seven. Off until
    /// "All Tags…" is clicked; per window, and deliberately not persisted — it is a disclosure, not
    /// a setting. Stored here because a Swift extension cannot hold state, and the section itself
    /// lives in `SidebarViewController+Tags`.
    var showsAllTags = false
    /// The tag names the Tags section was last built from, so a scan that discovers nothing new
    /// doesn't rebuild the sidebar. Tags are re-scanned on every directory change, so this is the
    /// difference between rebuilding on a real change and rebuilding constantly.
    var renderedTagNames: Set<String> = []

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
        observeSavedSearchChanges()
        observeServerConnectionChanges()
        observeServerConnectionActivity()
        observeTagChanges()
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

        var rows: [Row] = []
        // Saved searches lead the sidebar, above the standard Favorites/Volumes sections.
        let savedSearches = SavedSearchStore.load().searches
        if !savedSearches.isEmpty {
            rows.append(.header("Searches"))
            rows.append(contentsOf: savedSearches.map(Row.savedSearch))
        }
        let favorites = SidebarLocations.favorites()
        if !favorites.isEmpty {
            rows.append(.header("Favorites"))
            rows.append(contentsOf: favorites.map(Row.place))
        }
        let volumes = SidebarLocations.volumes()
        if !volumes.isEmpty {
            rows.append(.header("Volumes"))
            rows.append(contentsOf: volumes.map(Row.volume))
        }
        // Saved servers close the sidebar, grouped with the local volumes as the "places you browse"
        // (PLAN.md §M5 "a Servers sidebar section mirroring Searches").
        let servers = ServerConnectionStore.load().connections
        if !servers.isEmpty {
            rows.append(.header("Servers"))
            rows.append(contentsOf: servers.map(Row.server))
        }
        // Tags close the sidebar, where Finder puts them, and only when View ▸ Show Tags is on.
        rows.append(contentsOf: tagRows())
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

    /// Refresh a server row's spinner when a connect starts or finishes — in this window or another.
    /// Unlike a store change this needs no full rebuild (the rows themselves are unchanged), so it
    /// reloads only the server rows in place, leaving the current selection untouched.
    private func observeServerConnectionActivity() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(serverActivityChanged),
            name: ServerConnectionActivity.didChangeNotification,
            object: nil
        )
    }

    @objc private func serverActivityChanged() {
        let serverRows = rows.indices.filter { rows[$0].server != nil }
        guard !serverRows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(serverRows),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        let index = tableView.clickedRow
        guard rows.indices.contains(index) else { return }
        if let savedSearch = rows[index].savedSearch {
            delegate?.sidebar(self, didActivateSavedSearch: savedSearch)
        } else if let server = rows[index].server {
            delegate?.sidebar(self, didActivateServer: server)
        } else if let tag = rows[index].tag {
            delegate?.sidebar(self, didActivateTag: tag)
        } else if case .allTags = rows[index] {
            expandAllTags()
        } else if let path = rows[index].path {
            delegate?.sidebar(self, didActivate: path)
        }
    }

    /// Eject (or unmount) a removable volume via the workspace, surfacing any failure —
    /// a drive that's busy or in use should say so, not fail silently.
    private func eject(_ volume: MountedVolume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.path.localURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t eject “\(volume.name)”"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
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
        !rows[row].isHeader
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(title):
            let cell = reuse(SidebarHeaderView.identifier) as? SidebarHeaderView
            let header = cell ?? SidebarHeaderView()
            header.configure(title: title)
            return header
        case let .place(place):
            return itemCell(name: place.name, path: place.path, kind: place.kind, volume: nil)
        case let .volume(volume):
            return itemCell(name: volume.name, path: volume.path, kind: nil, volume: volume)
        case let .savedSearch(search):
            let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
            cell.configure(
                name: search.name,
                image: Self.savedSearchIcon,
                canEject: false,
                tooltip: savedSearchTooltip(search)
            )
            cell.onEject = nil
            cell.onDelete = { [weak self] in self?.confirmDeleteSavedSearch(named: search.name) }
            return cell
        case let .server(connection):
            let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
            cell.configure(
                name: connection.name,
                image: Self.serverIcon(for: connection.kind),
                canEject: false,
                tooltip: connection.address,
                isBusy: ServerConnectionActivity.shared.isConnecting(connection.name)
            )
            cell.onEject = nil
            cell.onDelete = { [weak self] in self?.confirmRemoveServer(named: connection.name) }
            return cell
        case let .tag(tag):
            return tagCell(for: tag)
        case .allTags:
            return allTagsCell()
        }
    }

    /// A per-protocol SF Symbol so a saved server reads as remote at a glance: a globe-ish network
    /// glyph for SFTP, a connected-drive glyph for an SMB share. Template so the source list tints
    /// it with the row's text color like the other sidebar glyphs.
    private static func serverIcon(for kind: ServerKind) -> NSImage {
        let symbol = kind == .smb ? "externaldrive.connected.to.line.below" : "network"
        return templateSymbol(symbol, pointSize: 14, describedAs: "Server")
    }

    /// A magnifying-glass SF Symbol so a saved search reads as a query, not a folder. Template
    /// so the source list tints it with the row's text color like the favorite glyphs.
    private static let savedSearchIcon = templateSymbol(
        "magnifyingglass",
        pointSize: 14,
        describedAs: "Saved search"
    )

    /// Every sidebar glyph is a template SF Symbol, so the source list tints it with the row's
    /// text color — and turns it white on the selected row — matching the label beside it.
    private static func templateSymbol(
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

    /// A tooltip describing where a saved search runs — the scope folder, or "Everywhere".
    private func savedSearchTooltip(_ search: SavedSearch) -> String {
        guard let scope = search.scope else { return "Search everywhere" }
        return "Search in “\(scope.lastComponent)”"
    }

    /// Build (or reuse) an item cell. Favorites get a per-kind SF Symbol so Documents,
    /// Downloads, Music, etc. read at a glance instead of all sharing the generic folder
    /// icon; volumes get a drive symbol the same way. A `volume` that can eject also
    /// gets the eject button wired.
    private func itemCell(
        name: String,
        path: VFSPath,
        kind: FavoritePlace.Kind?,
        volume: MountedVolume?
    ) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        let icon: NSImage
        if let kind {
            icon = Self.icon(for: kind)
        } else if let volume {
            icon = Self.templateSymbol(volume.symbolName, pointSize: 15, describedAs: volume.name)
        } else {
            icon = NSWorkspace.shared.icon(forFile: path.path)
            icon.size = NSSize(width: 18, height: 18)
        }
        let canEject = volume?.canEject ?? false
        cell.configure(name: name, image: icon, canEject: canEject, tooltip: capacityTooltip(volume))
        cell.onEject = canEject ? { [weak self] in volume.map { self?.eject($0) } } : nil
        cell.onDelete = nil // places/volumes aren't deletable (reset in case the cell was reused)
        return cell
    }

    /// A monochrome SF Symbol standing in for each favorite folder.
    private static func icon(for kind: FavoritePlace.Kind) -> NSImage {
        let symbol: String
        switch kind {
        case .home: symbol = "house"
        case .desktop: symbol = "menubar.dock.rectangle"
        case .documents: symbol = "doc"
        case .downloads: symbol = "arrow.down.circle"
        case .pictures: symbol = "photo"
        case .music: symbol = "music.note"
        case .movies: symbol = "film"
        case .applications: symbol = "square.grid.3x3.fill"
        }
        return templateSymbol(symbol, pointSize: 15)
    }

    private func reuse(_ identifier: NSUserInterfaceItemIdentifier) -> NSView? {
        tableView.makeView(withIdentifier: identifier, owner: self)
    }

    /// A "123 GB available of 456 GB" tooltip for volumes that report capacity.
    private func capacityTooltip(_ volume: MountedVolume?) -> String? {
        guard let volume, let total = volume.totalCapacity, let available = volume.availableCapacity else {
            return volume?.name
        }
        return "\(FileFormatting.byteString(available)) available of \(FileFormatting.byteString(total))"
    }
}

// MARK: - Right-click context menu

extension SidebarViewController: NSMenuDelegate {
    /// Build the right-click menu lazily from the clicked row, dispatching to the saved-search,
    /// server or tag management builder (in companion files). Any other row — a header, place, or
    /// volume — leaves the menu empty, so AppKit shows nothing.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        if let search = rows[row].savedSearch {
            buildSavedSearchMenu(menu, for: search)
        } else if let server = rows[row].server {
            buildServerMenu(menu, for: server)
        } else if let tag = rows[row].tag {
            buildTagMenu(menu, for: tag)
        }
    }
}
