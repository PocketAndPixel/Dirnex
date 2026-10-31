import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Recents, the Trash, a saved search and a tag picked without ⌘: their results replace what the
/// active tab shows, as a folder's listing does, and ⌘ opens them in a new tab instead.
///
/// The sidebar's half, every place carrying ⌘ to the window, is `SidebarNewTabTests`'. What is pinned
/// here is the pane's: where the results land, the fallback when the tab moved on while they were
/// gathered, and what replacing a folder leaves behind for the way back. A results listing never
/// enters the trail, so a listing over a folder needs ⌘[ to come back to that folder, on the row it
/// was left at and in its own sort, rather than one further back with the trail wiped.
@MainActor
@Suite("Results replace the tab's listing")
struct ResultsInPlaceTests {
    /// `a/` holding `sub/` and `one.txt`, and `b/` holding `b1.txt`, `b2.txt` and `folder/`. Listed
    /// by name with folders first, `folder` is `b`'s first row, so a cursor on `b2.txt` was put
    /// there; listed in Recents' sort, folders are not first.
    @MainActor
    private struct Fixture {
        let directory: URL
        let pane: PanelViewController

        var folderA: VFSPath { .local(directory.appendingPathComponent("a").path) }
        var folderB: VFSPath { .local(directory.appendingPathComponent("b").path) }
        var sub: VFSPath { folderA.appending("sub") }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ResultsInPlaceTests-\(UUID().uuidString)")
            for folder in ["a/sub", "b/folder"] {
                try FileManager.default.createDirectory(
                    at: directory.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            for name in ["a/one.txt", "b/b1.txt", "b/b2.txt"] {
                try Data("x".utf8).write(to: directory.appendingPathComponent(name))
            }
            pane = PanelViewController(
                backend: CompositeBackend(local: LocalBackend()),
                restoration: nil,
                defaultPath: .local(directory.appendingPathComponent("a").path),
                restorationKey: nil
            )
            // Loaded now, as the app's always is. A landing ends by focusing the table, which would
            // otherwise load the view then, and `viewDidLoad` re-lists the tab in front: over a Trash
            // listing that gathers the developer's real Trash, and without Full Disk Access raises
            // its alert as an app-modal window in the middle of the run (seen 2026-10-31).
            pane.loadViewIfNeeded()
            NotificationCenter.default.removeObserver(pane)
        }

        func remove() {
            pane.watcher = nil
            try? FileManager.default.removeItem(at: directory)
        }

        /// Navigate and wait for the listing and any walk to have landed.
        func go(to path: VFSPath) async throws {
            pane.navigate(to: path)
            try await settled(on: path)
        }

        func settled(on path: VFSPath) async throws {
            try await settleUntil {
                pane.panel.path == path && pane.tabs[pane.activeTabIndex].hasLoaded
                    && pane.tabs[pane.activeTabIndex].history.walk == nil
            }
        }

        /// The trail `a`, then `b` with the cursor on `b2.txt`.
        func browseToB() async throws {
            try await go(to: folderA)
            try await go(to: folderB)
            let index = try #require(pane.panel.displayedIndex(ofID: folderB.appending("b2.txt")))
            pane.panel.moveCursor(to: index)
            pane.cursorOnParentRow = false
        }

        /// Recents picked without ⌘ (`over`) or with it (`nil`), landed at once.
        func landRecents(over target: PanelViewController.ResultsTarget?) {
            pane.landResults([hit("recent.txt")], as: recents, over: target)
        }

        func hit(_ name: String) -> FileEntry {
            FileEntry(
                path: .local(directory.appendingPathComponent("elsewhere/\(name)").path),
                name: name,
                kind: .file,
                byteSize: 1,
                modificationDate: Date(timeIntervalSince1970: 1_000_000),
                creationDate: Date(timeIntervalSince1970: 900_000),
                isHidden: false,
                permissions: 0o644,
                inode: 9
            )
        }

        var recents: PanelViewController.ResultsPresentation {
            .init(
                pathSummary: PanelViewController.ResultsPresentation.recentsIdentity,
                sort: RecentsQuery.resultSort,
                query: nil,
                scope: nil,
                title: "Recents"
            )
        }
    }

    // MARK: - Where the results land

    @Test("without ⌘ the results replace the active tab's listing, and with ⌘ open beside it")
    func landsInPlaceOrInANewTab() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.browseToB()
        let tab = pane.tabs[0]

        fixture.landRecents(over: pane.resultsTarget(inNewTab: false))
        #expect(pane.tabs.count == 1)
        #expect(pane.tabs[0] === tab)
        #expect(pane.panel.path.backend == .search)
        #expect(tab.customTitle == "Recents")

        // The narrowness half: ⌘ leaves that tab as it is.
        fixture.landRecents(over: pane.resultsTarget(inNewTab: true))
        #expect(pane.tabs.count == 2)
        #expect(pane.activeTabIndex == 1)
        #expect(tab.panel.path.backend == .search)
    }

    /// A Spotlight search can take seconds. A tab walked off to another folder, or left for another
    /// tab, while its results were gathered is not where the user asked for them any more.
    @Test("results for a tab that moved on while they were gathered open a tab of their own")
    func movedOnTabGetsANewTab() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.browseToB()

        let walkedOff = pane.resultsTarget(inNewTab: false)
        try await fixture.go(to: fixture.folderA)
        fixture.landRecents(over: walkedOff)
        try #require(pane.tabs.count == 2)
        #expect(pane.tabs[0].panel.path == fixture.folderA)

        // Set rather than selected, as `SearchEditTests` does: selecting re-lists the tab, and that
        // listing would land in whichever tab is in front when it arrives.
        pane.activeTabIndex = 0
        let leftForAnother = pane.resultsTarget(inNewTab: false)
        pane.activeTabIndex = 1
        fixture.landRecents(over: leftForAnother)
        #expect(pane.tabs.count == 3)
        #expect(pane.tabs[0].panel.path == fixture.folderA)
    }

    @Test("a saved search's or a tag's hits replace the listing, carrying their name and query")
    func searchLandsInPlace() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.browseToB()
        let query = FileQuery(tags: ["Red"])

        pane.landSearchResults(
            [fixture.hit("tagged.txt")],
            truncated: false,
            query: query,
            scope: nil,
            landing: .init(title: "Red", over: pane.resultsTarget(inNewTab: false))
        )

        #expect(pane.tabs.count == 1)
        #expect(pane.isSearchResults)
        #expect(pane.tabs[0].customTitle == "Red")
        #expect(pane.tabs[0].searchQuery == query)
        #expect(pane.panel.model.listing.entries.map(\.name) == ["tagged.txt"])
    }

    /// The Trash is gathered from real directories, which its tab has to watch, and a listing that
    /// replaces it must stop watching them.
    @Test("a merged listing's sources are watched in its tab, and the next listing drops them")
    func mergedSourcesFollowTheListing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.browseToB()

        pane.landResults(
            [fixture.hit("trashed.txt")],
            as: pane.trashPresentation(),
            over: pane.resultsTarget(inNewTab: false),
            mergedFrom: [fixture.folderA]
        )
        #expect(pane.isTrashListing)
        #expect(pane.tabs[0].mergedSources == [fixture.folderA])

        fixture.landRecents(over: pane.resultsTarget(inNewTab: false))
        #expect(pane.tabs.count == 1)
        #expect(pane.tabs[0].mergedSources.isEmpty)
    }

    // MARK: - The way back

    @Test("⌘[ goes back to the folder the results replaced, on its row and in its sort")
    func backReturnsToTheFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.browseToB()
        let sort = pane.panel.model.sort
        #expect(sort != RecentsQuery.resultSort)

        fixture.landRecents(over: pane.resultsTarget(inNewTab: false))
        #expect(pane.panel.model.sort == RecentsQuery.resultSort)
        #expect(pane.canGoBack)

        pane.goBack(nil)
        try await fixture.settled(on: fixture.folderB)
        #expect(pane.panel.currentEntry?.name == "b2.txt")
        #expect(pane.panel.model.sort == sort)
        #expect(pane.tabs[0].customTitle == nil)
        #expect(pane.tabs[0].sortUnderResults == nil)

        // The rest of the trail is still there.
        pane.goBack(nil)
        try await fixture.settled(on: fixture.folderA)
    }

    /// With only the folder on the trail there is nothing older to step back to, and the results
    /// still have somewhere to go back from.
    @Test("⌘[ is open over results that replaced a tab's first folder")
    func backFromTheFirstFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.go(to: fixture.folderA)
        #expect(!pane.canGoBack)

        fixture.landRecents(over: pane.resultsTarget(inNewTab: false))
        #expect(pane.canGoBack)
        pane.goBack(nil)
        try await fixture.settled(on: fixture.folderA)
        #expect(!pane.canGoBack)
    }

    @Test("leaving the results for a folder steps on from the folder they replaced")
    func leavingKeepsTheTrail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.browseToB()
        let sort = pane.panel.model.sort

        fixture.landRecents(over: pane.resultsTarget(inNewTab: false))
        try await fixture.go(to: fixture.sub)
        #expect(pane.tabs[0].history.entries == [fixture.folderA, fixture.folderB, fixture.sub])
        #expect(pane.panel.model.sort == sort)

        pane.goBack(nil)
        try await fixture.settled(on: fixture.folderB)
    }

    /// The negative control for the three tests above: a tab that opened on results holds only their
    /// synthetic path, so it has no folder under them, and leaving starts a fresh trail as before.
    @Test("a tab that opened on results has nothing under them")
    func newResultsTabHasNoFolderUnder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.browseToB()

        fixture.landRecents(over: nil)
        #expect(pane.trailIndexUnderResults == nil)
        #expect(!pane.canGoBack)

        try await fixture.go(to: fixture.sub)
        #expect(pane.tabs[1].history.entries == [fixture.sub])
    }
}
