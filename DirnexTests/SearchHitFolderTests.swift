import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A folder moved or deleted takes the search hits inside it out of every results tab, and ⌘Z
/// brings them back with it (2026-11-05).
///
/// Until then only the row whose path was the folder's own left, so a hit inside it stayed and named
/// the folder's old place. The rule is the core's (`SearchSnapshotFolderTests`); what is pinned here
/// is that the pane's two ways in, `applySearchHitChanges` for a finished move and `runDelete` for
/// F8 and ⇧F8, reach it and remember what can come back. `SnapshotDisk` is a flat map rather than a
/// tree, so each test takes the inner hit off it by hand where the real disk would take it along
/// with the folder.
@MainActor
@Suite("A folder that left takes its search hits along")
struct SearchHitFolderTests {
    private static let results = VFSPath(backend: .search, path: "/Results")
    private static let work = VFSPath.local("/Users/tester/Work")
    private static let archive = VFSPath.local("/Users/tester/Archive")

    private static func hit(_ relative: String, kind: FileEntry.Kind = .file) -> FileEntry {
        let path = VFSPath.local(work.path + "/" + relative)
        return FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 128,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 900_000),
            isHidden: false,
            permissions: 0o644,
            inode: 7
        )
    }

    /// The reported search: `notes` in `~/Work`.
    private static let folder = hit("notes", kind: .directory)
    private static let inside = hit("notes/a.txt")
    private static let outside = hit("other/notes-c.txt")

    private static let presentation = PanelViewController.ResultsPresentation(
        pathSummary: "Results",
        sort: FileSort(key: .name),
        query: FileQuery(nameContains: "notes"),
        scope: nil,
        title: nil
    )

    private func names(_ tab: PanelTab) -> [String] {
        tab.panel.model.listing.entries.map(\.name).sorted()
    }

    /// A pane hosted in a window with its own first listing landed, then the hits installed — for
    /// the reason `SearchHitDeleteTests.loadedPane` gives: an unwaited first listing replaces them.
    private static func showing(
        _ entries: [FileEntry],
        on disk: SnapshotDisk
    ) async throws -> (PanelViewController, PanelTab) {
        let pane = TrashlessProbe.pane(with: disk, in: TrashlessProbe.window())
        await settle { pane.tabs[0].hasLoaded }
        try #require(pane.tabs[0].hasLoaded, "the pane's first listing never landed")
        pane.installResults(entries, as: presentation)
        let tab = pane.tabs[pane.activeTabIndex]
        try #require(tab.panel.model.listing.entries.count == entries.count, "the hits never landed")
        return (pane, tab)
    }

    /// The reported case: F6 on the folder hit, then ⌘Z.
    @Test("a moved folder hit takes the hits inside it, and ⌘Z brings them back")
    func movedFolderRoundTrips() async throws {
        let disk = SnapshotDisk(holding: [Self.folder, Self.inside, Self.outside])
        let (pane, tab) = try await Self.showing([Self.folder, Self.inside, Self.outside], on: disk)

        // What the window does when the job finishes: the report names the folder alone.
        disk.take(Self.folder.path)
        disk.take(Self.inside.path)
        pane.applySearchHitChanges(
            [.moved(Self.folder.path, to: Self.archive.appending("notes"))],
            canReturn: true
        )
        #expect(names(tab) == ["notes-c.txt"])
        #expect(tab.departedSearchHits[Self.inside.path] == Self.inside)

        disk.putBack(Self.folder)
        disk.putBack(Self.inside)
        pane.refreshCurrentDirectory()
        await settle { names(tab) == ["a.txt", "notes", "notes-c.txt"] }
        #expect(names(tab) == ["a.txt", "notes", "notes-c.txt"])
    }

    /// F8 on the folder hit, through the real delete pass, then ⌘Z.
    @Test("a trashed folder hit takes the hits inside it, and ⌘Z brings them back")
    func trashedFolderRoundTrips() async throws {
        let disk = SnapshotDisk(holding: [Self.folder, Self.inside, Self.outside])
        let (pane, tab) = try await Self.showing([Self.folder, Self.inside, Self.outside], on: disk)

        disk.take(Self.inside.path)
        pane.runDelete([Self.folder.path], permanent: false)
        await settle { names(tab) == ["notes-c.txt"] }
        #expect(names(tab) == ["notes-c.txt"])
        #expect(tab.departedSearchHits[Self.inside.path] == Self.inside)
        // The delete's own refresh checks the disk too; let it finish first, or the files put back
        // below are found by that check and the refresh under test proves nothing.
        try await holdOutTheDeletePasses()

        disk.putBack(Self.folder)
        disk.putBack(Self.inside)
        pane.refreshCurrentDirectory()
        await settle { names(tab) == ["a.txt", "notes", "notes-c.txt"] }
        #expect(names(tab) == ["a.txt", "notes", "notes-c.txt"])
    }

    /// ⇧F8 has nothing to come back from, so neither the folder nor what was inside it is followed.
    @Test("a permanently deleted folder hit takes the hits inside it, and follows none")
    func permanentFolderFollowsNone() async throws {
        let disk = SnapshotDisk(holding: [Self.folder, Self.inside, Self.outside])
        let (pane, tab) = try await Self.showing([Self.folder, Self.inside, Self.outside], on: disk)

        disk.take(Self.inside.path)
        pane.runDelete([Self.folder.path], permanent: true)
        await settle { names(tab) == ["notes-c.txt"] }
        #expect(names(tab) == ["notes-c.txt"])
        #expect(tab.departedSearchHits.isEmpty)
    }

    /// Moved or deleted from a folder tab, where the folder was never a hit: a results tab behind it
    /// loses the hits inside, keeps the rest, and can bring them back. The folder tab itself
    /// re-lists, and is left alone.
    @Test("a folder that was not a hit still takes the hits inside it from a tab behind")
    func folderFromAFolderTab() {
        // The window's call when a move job finishes, and what F8 in the folder tab calls.
        let gestures: [(String, (PanelViewController) -> Void)] = [
            ("move", { pane in
                pane.applySearchHitChanges(
                    [.moved(Self.folder.path, to: Self.archive.appending("notes"))],
                    canReturn: true
                )
            }),
            ("trash", { pane in pane.noteSearchHitsDeleted([Self.folder.path], permanent: false) })
        ]
        for (gesture, run) in gestures {
            let pane = PanelViewController(
                backend: CompositeBackend(local: LocalBackend()),
                restoration: nil,
                defaultPath: Self.results,
                restorationKey: nil
            )
            pane.panel = Panel(model: DirectoryModel(
                listing: DirectoryListing(path: Self.results, entries: [Self.inside, Self.outside]),
                sort: FileSort(key: .name)
            ))
            let search = pane.tabs[0]
            let folderTab = PanelTab(panel: Panel(model: DirectoryModel(
                listing: DirectoryListing(path: Self.work, entries: [Self.folder])
            )))
            pane.tabs.append(folderTab)
            pane.activeTabIndex = 1

            run(pane)

            #expect(names(search) == ["notes-c.txt"], "\(gesture)")
            #expect(search.departedSearchHits[Self.inside.path] == Self.inside, "\(gesture)")
            #expect(names(folderTab) == ["notes"], "\(gesture)")
        }
    }
}
