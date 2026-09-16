import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Where View ▸ Focus Sidebar puts the cursor: on the place the active pane is in.
///
/// The sidebar is built from groups handed in rather than from its stores, because this target runs
/// inside the app and the stores are the developer's own sidebar.
@Suite("Sidebar focus lands on the pane's place")
@MainActor
struct SidebarFocusTests {
    private let home = SidebarPlace.favorite(FavoriteEntry(path: .local("/Users/u")))
    private let iCloud = SidebarPlace.iCloudDrive(
        .local("/Users/u/Library/Mobile Documents/com~apple~CloudDocs")
    )

    private var groups: [SidebarPlaceGroup] {
        [
            SidebarPlaceGroup(section: nil, places: [.recents]),
            SidebarPlaceGroup(section: .favorites, places: [home]),
            SidebarPlaceGroup(section: .icloud, places: [.photos, iCloud]),
            SidebarPlaceGroup(section: nil, places: [.trash])
        ]
    }

    private func sidebar(collapsing collapsed: Set<SidebarSection> = []) -> SidebarViewController {
        let sidebar = SidebarViewController()
        sidebar.loadView()
        sidebar.sectionCollapse = SidebarSectionCollapse(collapsed: collapsed)
        sidebar.placeGroups = groups
        var rows: [SidebarViewController.Row] = []
        for group in groups {
            sidebar.render(group, into: &rows)
        }
        sidebar.rows = rows
        sidebar.tableView.reloadData()
        return sidebar
    }

    private func row(_ sidebar: SidebarViewController, of place: SidebarPlace) -> Int? {
        sidebar.rows.firstIndex { $0.place == place }
    }

    /// The reported case: the merged listing's path is `icloud:/…`, which no row's path equals, so
    /// the cursor used to fall to Recents.
    @Test("from iCloud Drive's listing, the cursor lands on iCloud Drive")
    func iCloudListing() {
        let sidebar = sidebar()
        let location = SidebarPaneLocation(path: ICloudLocation.mergedPath)
        #expect(sidebar.row(showing: location) == row(sidebar, of: iCloud))
    }

    @Test("from a folder inside a pinned one, the cursor lands on the pin")
    func insideAFavorite() {
        let sidebar = sidebar()
        let location = SidebarPaneLocation(path: .local("/Users/u/Dev/Common"))
        #expect(sidebar.row(showing: location) == row(sidebar, of: home))
    }

    @Test("from a Recents tab, the cursor lands on Recents rather than by default")
    func recentsTab() {
        let sidebar = sidebar()
        let location = SidebarPaneLocation(path: SidebarPlaceLocator.recentsPath)
        #expect(sidebar.row(showing: location) == row(sidebar, of: .recents))
        #expect(
            sidebar.row(showing: SidebarPaneLocation(path: VFSPath(backend: .trash, path: "/Trash")))
                == row(sidebar, of: .trash)
        )
    }

    @Test("a place inside a folded section lands on the section's header")
    func foldedSection() {
        let sidebar = sidebar(collapsing: [.icloud])
        #expect(row(sidebar, of: iCloud) == nil)
        let location = SidebarPaneLocation(path: ICloudLocation.mergedPath)
        #expect(sidebar.row(showing: location) == sidebar.headerRow(of: .icloud))
    }

    @Test("a location no place holds has no row, and the caller falls back")
    func noPlace() {
        let sidebar = sidebar()
        let location = SidebarPaneLocation(path: .local("/private/tmp"))
        #expect(sidebar.row(showing: location) == nil)
    }

    // MARK: - What the pane reports

    private func pane(at path: VFSPath) -> PanelViewController {
        PanelViewController(
            backend: LocalBackend(), restoration: nil, defaultPath: path, restorationKey: nil
        )
    }

    @Test("a pane inside an archive reports the archive file beside its path")
    func paneInArchive() {
        let file = "/Users/u/Downloads/pkg.zip"
        let inside = VFSPath(backend: .archive(forArchiveAt: file), path: "/docs")
        let location = pane(at: inside).sidebarLocation
        #expect(location.path == inside)
        #expect(location.archiveFile == .local(file))
        #expect(pane(at: .local("/Users/u")).sidebarLocation.archiveFile == nil)
    }

    @Test("a results tab reports the query behind it")
    func paneResultsTab() {
        let pane = pane(at: .local("/Users/u"))
        let query = FileQuery(tags: ["Red"])
        pane.tabs[pane.activeTabIndex].searchQuery = query
        pane.tabs[pane.activeTabIndex].searchScope = .local("/Users/u")
        #expect(pane.sidebarLocation.searchQuery == query)
        #expect(pane.sidebarLocation.searchScope == .local("/Users/u"))
    }
}
