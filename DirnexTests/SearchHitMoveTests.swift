import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A search hit moved with F6 (or dragged, or ⌥⌘V'd) leaves the results it was found in, and ⌘Z
/// brings it back.
///
/// A move is a queued job, and the window hears it finish with the report's outcomes and no tab
/// attached; it hands `SearchSnapshot.changes(made:by:)` to both panes' `applySearchHitChanges`.
/// That one line is checked live; what is pinned here is everything it calls. Which items count as
/// moved — never a skipped or stopped one — is pinned against the real engine in the core's
/// `SearchSnapshotTests`.
@MainActor
@Suite("Moving a search hit")
struct SearchHitMoveTests {
    private static let results = VFSPath(backend: .search, path: "/Results")
    private static let documents = VFSPath.local("/Users/tester/Documents")
    private static let desktop = VFSPath.local("/Users/tester/Desktop")

    private static func hit(_ name: String, in directory: VFSPath = documents) -> FileEntry {
        FileEntry(
            path: directory.appending(name),
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

    private func names(_ tab: PanelTab) -> [String] {
        tab.panel.model.listing.entries.map(\.name).sorted()
    }

    /// An unloaded pane on a real `CompositeBackend`, holding `entries` as search hits — enough for
    /// everything that does not wait on the disk.
    private static func pane(_ entries: [FileEntry]) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: results,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: results, entries: entries),
            sort: FileSort(key: .name)
        ))
        return pane
    }

    /// The reported case, then ⌘Z. A loaded pane landing its hits the way a search does, for the
    /// reason `SearchHitDeleteTests.loadedPane` gives: an unwaited first listing replaces them.
    @Test("a moved hit leaves the results, and comes back with ⌘Z")
    func movedHitRoundTrips() async throws {
        let window = TrashlessProbe.window()
        let moved = Self.hit("moved.txt")
        let kept = Self.hit("kept.txt")
        let disk = SnapshotDisk(holding: [moved, kept])
        let pane = TrashlessProbe.pane(with: disk, in: window)
        await settle { pane.tabs[0].hasLoaded }
        try #require(pane.tabs[0].hasLoaded, "the pane's first listing never landed")
        pane.installResults([moved, kept], as: PanelViewController.ResultsPresentation(
            pathSummary: "Results",
            sort: FileSort(key: .name),
            query: FileQuery(nameContains: "t"),
            scope: nil,
            title: nil
        ))
        let tab = pane.tabs[pane.activeTabIndex]
        try #require(names(tab) == ["kept.txt", "moved.txt"], "the hits never landed")

        // What the window does when the job finishes, with the file gone from where it was.
        disk.take(moved.path)
        pane.applySearchHitChanges(
            [.moved(moved.path, to: Self.desktop.appending("moved.txt"))],
            canReturn: true
        )
        #expect(names(tab) == ["kept.txt"])
        #expect(tab.departedSearchHits[moved.path] == moved)

        // ⌘Z puts the file back where it was found, and the refresh undo runs finds it.
        disk.putBack(moved)
        pane.refreshCurrentDirectory()
        await settle { names(tab) == ["kept.txt", "moved.txt"] }
        #expect(names(tab) == ["kept.txt", "moved.txt"])
    }

    /// A rename that had to run as a job is a move that stayed in its own folder. Before this, such
    /// a hit kept its old name until the search ran again; dropping it would have been worse, since
    /// the file is still exactly where it was found.
    @Test("a queued rename renames the row and keeps the cursor on it")
    func queuedRenameRenamesTheRow() throws {
        let renamed = Self.hit("a.txt")
        let pane = Self.pane([renamed, Self.hit("m.txt")])
        try #require(pane.panel.currentEntry?.name == "a.txt")

        pane.applySearchHitChanges(
            [.moved(renamed.path, to: Self.documents.appending("z.txt"))],
            canReturn: true
        )

        #expect(names(pane.tabs[0]) == ["m.txt", "z.txt"])
        #expect(pane.panel.currentEntry?.path == Self.documents.appending("z.txt"))
        #expect(pane.tabs[0].departedSearchHits.isEmpty)
    }

    /// Following a hit costs a `stat` on every refresh of the tab, which for a server would be a
    /// round trip apiece: a hit moved off one leaves, and is not followed.
    @Test("a hit moved off a server leaves and is not followed")
    func remoteHitIsNotFollowed() {
        let server = VFSPath(
            backend: .sftp(SFTPLocation(host: "srv", username: "oleg")),
            path: "/home/oleg"
        )
        let remote = Self.hit("r.txt", in: server)
        let pane = Self.pane([remote])

        pane.applySearchHitChanges(
            [.moved(remote.path, to: Self.desktop.appending("r.txt"))],
            canReturn: true
        )

        #expect(names(pane.tabs[0]).isEmpty)
        #expect(pane.tabs[0].departedSearchHits.isEmpty)
    }

    /// The narrowness control: a moved file that some *folder* tab is showing is that folder's to
    /// re-list, and the results tab beside it loses only what moved.
    @Test("only results tabs change, and only by what moved")
    func onlyResultsTabsChange() {
        let pane = Self.pane([Self.hit("a.txt"), Self.hit("b.txt")])
        let folder = PanelTab(panel: Panel(model: DirectoryModel(
            listing: DirectoryListing(path: Self.documents, entries: [Self.hit("a.txt")])
        )))
        pane.tabs.append(folder)

        pane.applySearchHitChanges(
            [.moved(Self.hit("a.txt").path, to: Self.desktop.appending("a.txt"))],
            canReturn: true
        )

        #expect(names(pane.tabs[0]) == ["b.txt"])
        #expect(names(folder) == ["a.txt"])
    }
}
