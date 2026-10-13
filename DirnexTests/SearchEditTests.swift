import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Find Files opened on a search that already ran, rather than empty.
///
/// Held to one property: whatever the dialog can produce, it opens back on exactly. A value it
/// cannot show is the quiet failure — an edit that opens on "Any kind" has widened the search before
/// the user touched anything — so the round trip is asserted over every value the menus offer, and
/// separately over values they do not.
@MainActor
@Suite("Find Files dialog: opening on a search")
struct SearchControllerOpeningTests {
    private func opened(on query: FileQuery, everything: Bool = false) -> SearchController {
        let controller = SearchController(
            currentFolderName: "Documents",
            fields: .indexed,
            connectionRootTitle: nil
        )
        controller.open(on: query, everything: everything)
        controller.loadViewIfNeeded()
        return controller
    }

    @Test("every value the menus offer opens back on itself")
    func everyMenuValueRoundTrips() {
        for kind in SearchFilterOptions.kinds.map(\.kind) {
            let query = FileQuery(nameContains: "a", kinds: kind.map { [$0] } ?? [])
            #expect(opened(on: query).currentQuery() == query, "\(String(describing: kind))")
        }
        for bytes in SearchFilterOptions.sizes.map(\.bytes) {
            let query = FileQuery(nameContains: "a", minSizeBytes: bytes)
            #expect(opened(on: query).currentQuery() == query, "\(String(describing: bytes))")
        }
        for age in SearchFilterOptions.ages.map(\.age) {
            let query = FileQuery(nameContains: "a", modifiedWithin: age)
            #expect(opened(on: query).currentQuery() == query, "\(String(describing: age))")
        }
    }

    @Test("the typed fields and the tag chips open back on themselves")
    func typedFieldsRoundTrip() {
        let query = FileQuery(
            nameContains: "invoice",
            contentContains: "total due",
            kinds: [.document],
            minSizeBytes: 1_048_576,
            modifiedWithin: .month,
            tags: ["Work", "Red", "Urgent"]
        )
        #expect(opened(on: query).currentQuery() == query)
        // A tag search alone, which is what the sidebar's tag rows run.
        let tagOnly = FileQuery(tags: ["Red"])
        #expect(opened(on: tagOnly).currentQuery() == tagOnly)
    }

    @Test("the scope option opens on the one the search ran with")
    func scopeRoundTrips() {
        let query = FileQuery(nameContains: "a")
        #expect(opened(on: query, everything: false).currentScope == .currentFolder)
        #expect(opened(on: query, everything: true).currentScope == .everything)
    }

    /// Nothing the dialog writes holds these, so the fixed menus cannot name them; a hand-written
    /// saved search could. Opening them on the nearest item — or on "Any" — would change the search.
    @Test("a kind set or a size the menus cannot name is kept, not widened")
    func unnamedValuesAreKept() {
        let query = FileQuery(kinds: [.image, .movie], minSizeBytes: 3_000_000)
        let controller = opened(on: query)
        #expect(controller.currentQuery() == query)
    }

    /// The control for the test above: an *empty* query must not grow extra items, or the round
    /// trip would be passing on items that are always there.
    @Test("an empty query opens on the menus' first items and adds nothing")
    func emptyQueryAddsNothing() {
        let controller = opened(on: FileQuery())
        #expect(controller.currentQuery() == FileQuery())
        #expect(controller.currentQuery().isEmpty)
    }
}

/// Editing the search behind a results tab, and where the edited hits land.
@MainActor
@Suite("Editing a results tab")
struct SearchEditTests {
    private static let documents = VFSPath.local("/Users/tester/Documents")

    private static func hit(_ name: String) -> FileEntry {
        FileEntry(
            path: documents.appending(name),
            name: name,
            kind: .file,
            byteSize: 128,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 900_000),
            isHidden: false,
            permissions: 0o644,
            inode: 7
        )
    }

    /// A pane whose only tab is a search's results — the shape `openResults` leaves.
    private static func resultsPane(
        query: FileQuery,
        scope: VFSPath?,
        origin: VFSPath? = documents,
        title: String? = nil
    ) -> PanelViewController {
        let path = VFSPath(backend: .search, path: "/" + LocalizedCatalog.summary(of: query))
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: path, entries: [hit("old.txt")]),
            sort: FileSort(key: .name)
        ))
        let tab = pane.tabs[pane.activeTabIndex]
        tab.hasLoaded = true
        tab.searchQuery = query
        tab.searchScope = scope
        tab.searchOrigin = origin
        tab.customTitle = title
        return pane
    }

    private func names(in tab: PanelTab) -> [String] {
        tab.panel.model.listing.entries.map(\.name)
    }

    // MARK: - The dialog an edit opens

    /// The trap the edit is built around, end to end in the pane. The results tab's own path is
    /// `search:/…`; a dialog built from it hides Content and Tags, and the edited search drops them.
    @Test("an edited content search keeps its content field")
    func editKeepsContent() throws {
        let query = FileQuery(contentContains: "total due", tags: ["Work"])
        let pane = Self.resultsPane(query: query, scope: nil)

        let controller = try #require(pane.makeEditSearchController())
        controller.loadViewIfNeeded()
        #expect(controller.currentQuery() == query)
        #expect(controller.currentScope == .everything)

        // The negative control: the same dialog built from the tab's own path drops both terms.
        let fromTab = pane.makeSearchController(searching: pane.panel.path)
        fromTab.open(on: query, everything: true)
        fromTab.loadViewIfNeeded()
        #expect(fromTab.currentQuery().contentContains.isEmpty)
        #expect(fromTab.currentQuery().tags.isEmpty)
    }

    @Test("a This Folder search opens on This Folder")
    func editKeepsFolderScope() throws {
        let query = FileQuery(nameContains: "invoice")
        let pane = Self.resultsPane(query: query, scope: Self.documents)
        let controller = try #require(pane.makeEditSearchController())
        controller.loadViewIfNeeded()
        #expect(controller.currentScope == .currentFolder)
    }

    @Test("⌥F7 edits on a tab of search hits, and nowhere else")
    func onlySearchTabsEdit() {
        let search = Self.resultsPane(query: FileQuery(nameContains: "a"), scope: nil)
        #expect(search.canEditCurrentSearch)
        #expect(search.canFindFiles)

        // Recents rides the same machinery with no query behind it.
        let recents = Self.resultsPane(query: FileQuery(nameContains: "a"), scope: nil)
        recents.tabs[0].searchQuery = nil
        #expect(!recents.canEditCurrentSearch)
        #expect(recents.makeEditSearchController() == nil)

        let folder = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: Self.documents,
            restorationKey: nil
        )
        #expect(!folder.canEditCurrentSearch)
    }

    // MARK: - Where the edited hits land

    @Test("the edited hits replace the tab's, in the same tab")
    func editReplacesInPlace() {
        let pane = Self.resultsPane(query: FileQuery(nameContains: "old"), scope: nil)
        let tab = pane.tabs[0]
        let edited = FileQuery(nameContains: "new")

        pane.landSearchResults(
            [Self.hit("new.txt")],
            truncated: false,
            query: edited,
            scope: Self.documents,
            landing: .init(origin: Self.documents, tab: tab)
        )

        #expect(pane.tabs.count == 1)
        #expect(pane.tabs[0] === tab)
        #expect(names(in: tab) == ["new.txt"])
        #expect(tab.searchQuery == edited)
        #expect(tab.searchScope == Self.documents)
        #expect(tab.searchOrigin == Self.documents)
        #expect(
            tab.panel.path == VFSPath(
                backend: .search,
                path: "/" + LocalizedCatalog.summary(of: edited)
            )
        )
    }

    @Test("an edit takes a saved search's name off the tab, and Save Search offers it back")
    func editDropsTheSavedName() {
        let query = FileQuery(nameContains: "jmeter")
        let pane = Self.resultsPane(query: query, scope: nil, origin: nil, title: "JMeter logs")
        let tab = pane.tabs[0]
        let edited = FileQuery(nameContains: "jmeter", kinds: [.document])

        pane.landSearchResults(
            [Self.hit("run.log")],
            truncated: false,
            query: edited,
            scope: nil,
            landing: .init(tab: tab)
        )

        #expect(tab.customTitle == nil)
        #expect(pane.savedSearchNameToOffer(for: tab, query: edited) == "JMeter logs")
    }

    /// The control for the test above: the same search run again is still that saved search — which
    /// is also how the sidebar recognizes its tab — so the name stays.
    @Test("running the search again unchanged keeps the name")
    func unchangedRunKeepsTheName() {
        let query = FileQuery(nameContains: "jmeter")
        let pane = Self.resultsPane(query: query, scope: nil, origin: nil, title: "JMeter logs")
        let tab = pane.tabs[0]

        pane.landSearchResults(
            [Self.hit("run.log")],
            truncated: false,
            query: query,
            scope: nil,
            landing: .init(tab: tab)
        )

        #expect(tab.customTitle == "JMeter logs")
        #expect(names(in: tab) == ["run.log"])
    }

    @Test("Save Search offers the tab's name before the query's")
    func saveOffersTheName() {
        let query = FileQuery(nameContains: "jmeter")
        let pane = Self.resultsPane(query: query, scope: nil)
        let tab = pane.tabs[0]
        #expect(pane.savedSearchNameToOffer(for: tab, query: query) == "jmeter")
        tab.titleBeforeEdit = "Old name"
        #expect(pane.savedSearchNameToOffer(for: tab, query: query) == "Old name")
        tab.customTitle = "Saved name"
        #expect(pane.savedSearchNameToOffer(for: tab, query: query) == "Saved name")
    }

    /// A content search can take seconds, and the user may switch tabs while it runs: the hits
    /// belong to the tab that was edited, not to whichever is in front when they land.
    @Test("hits for a tab in the background land there and leave the front tab alone")
    func backgroundTabIsReplaced() {
        let pane = Self.resultsPane(query: FileQuery(nameContains: "old"), scope: nil)
        let edited = pane.tabs[0]
        let front = PanelTab(panel: Panel(model: DirectoryModel(
            listing: DirectoryListing(path: Self.documents, entries: [Self.hit("keep.txt")])
        )))
        pane.tabs.append(front)
        pane.activeTabIndex = 1

        pane.landSearchResults(
            [Self.hit("new.txt")],
            truncated: false,
            query: FileQuery(nameContains: "new"),
            scope: nil,
            landing: .init(tab: edited)
        )

        #expect(pane.tabs.count == 2)
        #expect(pane.activeTabIndex == 1)
        #expect(names(in: edited) == ["new.txt"])
        #expect(names(in: front) == ["keep.txt"])
    }

    /// A tab closed, or walked off to a folder, while its search ran has stopped being the search:
    /// replacing it would yank the user out of where they went. The hits get a tab of their own.
    @Test("hits for a tab that stopped being a search open a new tab")
    func departedTabGetsANewTab() {
        let pane = Self.resultsPane(query: FileQuery(nameContains: "old"), scope: nil)
        let edited = pane.tabs[0]
        edited.panel = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: Self.documents, entries: [Self.hit("keep.txt")])
        ))
        edited.clearResultsIdentity()

        pane.landSearchResults(
            [Self.hit("new.txt")],
            truncated: false,
            query: FileQuery(nameContains: "new"),
            scope: nil,
            landing: .init(tab: edited)
        )

        #expect(pane.tabs.count == 2)
        #expect(names(in: edited) == ["keep.txt"])
        #expect(names(in: pane.tabs[pane.activeTabIndex]) == ["new.txt"])
    }
}
