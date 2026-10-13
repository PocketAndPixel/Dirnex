import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Deleting a search hit where it was found: F8 and ⇧F8 in a results tab, the row leaving the
/// snapshot, and ⌘Z bringing it back.
///
/// Until 2026-10-14 the gate asked the pane, whose `search:` container deletes nothing, so every
/// search result was refused. It now asks each row's own directory (`DeleteRouting`), the way F2
/// does — and since a snapshot re-lists nothing, the pane takes deleted hits out by hand and puts
/// trashed ones back when they reappear (`SearchSnapshot`).
@MainActor
@Suite("Deleting a search hit")
struct SearchHitDeleteTests {
    private static let results = VFSPath(backend: .search, path: "/Results")
    private static let documents = VFSPath.local("/Users/tester/Documents")

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

    private static func results(_ entries: [FileEntry], at path: VFSPath = results) -> Panel {
        Panel(model: DirectoryModel(
            listing: DirectoryListing(path: path, entries: entries),
            sort: FileSort(key: .name)
        ))
    }

    private static func menuItem(_ action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        item.action = action
        return item
    }

    private static let trashItem = menuItem(#selector(PanelViewController.moveSelectionToTrash(_:)))
    private static let deleteItem = menuItem(
        #selector(PanelViewController.deleteSelectionPermanently(_:))
    )

    /// A results pane on a real `CompositeBackend`, which is what makes the gate observable: a pane
    /// on a bare `LocalBackend` answers its own capabilities for the container and the rows alike,
    /// so the old gate and the new one would agree there (docs/NOTES.md ▸ Design lessons).
    private static func compositePane(_ entries: [FileEntry]) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: results,
            restorationKey: nil
        )
        pane.panel = results(entries)
        return pane
    }

    private func names(_ tab: PanelTab) -> [String] {
        tab.panel.model.listing.entries.map(\.name).sorted()
    }

    // MARK: - The gate

    /// The reported gap. The first expectation is the negative control: it is what the gate used to
    /// ask, and it still says no, so the two after it can only be passing on the row.
    @Test("Move to Trash and Delete Permanently are offered on a search hit")
    func offeredOnAHit() {
        let pane = Self.compositePane([Self.hit("a.txt")])
        #expect(pane.backend.capabilities(for: Self.results).deleteStrategy == .unsupported)

        #expect(pane.validateMenuItem(Self.trashItem))
        #expect(pane.validateMenuItem(Self.deleteItem))
        #expect(pane.deleteStrategy(for: pane.recursiveTargets()) == .trash)
    }

    /// The narrowness control: a walk inside a zip lands hits that are archive members, which the
    /// VFS primitives cannot delete. They stay refused, as they are in a browsed nested archive.
    @Test("a hit inside an archive is still refused")
    func archiveHitIsRefused() {
        let inner = VFSPath(backend: .archive(forArchiveAt: "/Users/tester/pkg.zip"), path: "/docs")
        let pane = Self.compositePane([Self.hit("a.txt", in: inner)])
        #expect(!pane.validateMenuItem(Self.trashItem))
        #expect(!pane.validateMenuItem(Self.deleteItem))
    }

    @Test("an empty results tab offers nothing")
    func emptyResultsOfferNothing() {
        let pane = Self.compositePane([])
        #expect(!pane.validateMenuItem(Self.trashItem))
        #expect(!pane.validateMenuItem(Self.deleteItem))
    }

    /// A hit somewhere F8 cannot use the Trash is the gesture degrading the way it does in that
    /// folder: a confirmed permanent delete, never a Trash move the backend would refuse.
    @Test("a hit already in a Trash is deleted for good")
    func trashedHitIsPermanent() {
        let trash = VFSPath.local(NSHomeDirectory() + "/.Trash")
        let pane = Self.compositePane([Self.hit("a.txt"), Self.hit("b.txt", in: trash)])
        pane.panel.selectAll()
        #expect(pane.deleteStrategy(for: pane.recursiveTargets()) == .permanent)
    }

    /// The key itself, through the real routing: ⇧F8 on a hit raises the permanent-delete question
    /// (where it used to return in silence), and declining it deletes nothing.
    @Test("⇧F8 on a hit asks, and Cancel leaves it")
    func permanentKeyAsks() async throws {
        let window = TrashlessProbe.window()
        let pane = TrashlessProbe.pane(with: CompositeBackend(local: LocalBackend()), in: window)
        pane.panel = Self.results([Self.hit("a.txt")])

        pane.deleteSelectionPermanently(nil)

        // `beginSheetModal` attaches before it returns, so a sheet the key raised is already here.
        let sheet = try #require(window.attachedSheet, "⇧F8 on a search hit raised nothing")
        try #require(TrashlessProbe.cancelButton(in: sheet)).performClick(nil)
        await settle { window.attachedSheet == nil }
        #expect(names(pane.tabs[0]) == ["a.txt"])
    }

    /// The same key on a row that cannot be deleted — the control that keeps the test above from
    /// passing on a key that now asks about everything.
    @Test("⇧F8 on an archive hit raises nothing")
    func permanentKeyRefusesArchiveHit() {
        let window = TrashlessProbe.window()
        let pane = TrashlessProbe.pane(with: CompositeBackend(local: LocalBackend()), in: window)
        let inner = VFSPath(backend: .archive(forArchiveAt: "/Users/tester/pkg.zip"), path: "/docs")
        pane.panel = Self.results([Self.hit("a.txt", in: inner)])

        pane.deleteSelectionPermanently(nil)

        #expect(window.attachedSheet == nil)
    }

    // MARK: - The snapshot

    /// What a search hands `openResults` / `installResults`, the two ways hits reach a pane.
    private static let presentation = PanelViewController.ResultsPresentation(
        pathSummary: "Results",
        sort: FileSort(key: .name),
        query: FileQuery(nameContains: "t"),
        scope: nil,
        title: nil
    )

    /// A pane hosted in a window, its own first listing **landed** before anything else happens.
    ///
    /// Loading the view starts a listing of the pane's folder, and that listing installs into
    /// whichever tab is in front when it arrives — so a snapshot put in place before it lands is
    /// silently replaced by an empty folder, and a test asserting that rows went away passes on a
    /// pane that never held them. Measured: the permanent-delete test below passed that way.
    private static func loadedPane(
        with backend: any VFSBackend,
        in window: NSWindow
    ) async throws -> PanelViewController {
        let pane = TrashlessProbe.pane(with: backend, in: window)
        await settle { pane.tabs[0].hasLoaded }
        try #require(pane.tabs[0].hasLoaded, "the pane's first listing never landed")
        return pane
    }

    /// Land `entries` in the tab in front, the way an edited search does.
    private func showing(_ entries: [FileEntry], in pane: PanelViewController) throws -> PanelTab {
        pane.installResults(entries, as: Self.presentation)
        let tab = pane.tabs[pane.activeTabIndex]
        try #require(names(tab) == entries.map(\.name).sorted(), "the hits never landed")
        return tab
    }

    /// The whole round trip: the row goes with the file, comes back when ⌘Z puts the file back,
    /// and goes again when ⇧⌘Z sends it away. Undo is played by the disk rather than the journal,
    /// because that is what the pane reads — which is also why a partial undo needs no test of
    /// its own here (`SearchSnapshotTests`).
    @Test("a trashed hit leaves the snapshot, and comes back with ⌘Z")
    func trashedHitRoundTrips() async throws {
        let window = TrashlessProbe.window()
        let gone = Self.hit("gone.txt")
        let kept = Self.hit("kept.txt")
        let disk = SnapshotDisk(holding: [gone, kept])
        let pane = try await Self.loadedPane(with: disk, in: window)
        let tab = try showing([gone, kept], in: pane)

        pane.runDelete([gone.path], permanent: false)
        await settle { names(tab) == ["kept.txt"] }
        #expect(names(tab) == ["kept.txt"])
        #expect(tab.departedSearchHits[gone.path] == gone)
        // The delete's own refresh checks the disk too; let it finish, or the file put back below
        // is found by that check and the refresh under test proves nothing.
        try await holdOutTheDeletePasses()

        disk.putBack(gone)
        pane.refreshCurrentDirectory()
        await settle { names(tab) == ["gone.txt", "kept.txt"] }
        #expect(names(tab) == ["gone.txt", "kept.txt"])

        disk.take(gone.path)
        pane.refreshCurrentDirectory()
        await settle { names(tab) == ["kept.txt"] }
        #expect(names(tab) == ["kept.txt"])
    }

    /// Undo refreshes only the tabs on screen, so the row has to come back when its tab does.
    @Test("a hit put back while its tab was in the background is there on switching back")
    func backgroundUndoShowsOnSwitch() async throws {
        let window = TrashlessProbe.window()
        let gone = Self.hit("gone.txt")
        let disk = SnapshotDisk(holding: [gone])
        let pane = try await Self.loadedPane(with: disk, in: window)
        pane.openResults([gone], truncated: false, as: Self.presentation)
        let search = pane.tabs[1]
        try #require(pane.activeTabIndex == 1 && names(search) == ["gone.txt"])

        pane.runDelete([gone.path], permanent: false)
        await settle { names(search).isEmpty }
        try #require(names(search).isEmpty, "the delete never took the row out")
        // As above: the delete's own refresh must not be the one that finds the file back.
        try await holdOutTheDeletePasses()
        pane.selectTab(at: 0)
        disk.putBack(gone)
        pane.selectTab(at: 1)

        await settle { names(search) == ["gone.txt"] }
        #expect(names(search) == ["gone.txt"])
    }

    /// A permanent delete has nothing to come back from, so its row is not followed: a file later
    /// created under the same name is the world changing under a snapshot, which it does not track.
    @Test("a permanently deleted hit leaves the snapshot and is not followed")
    func permanentHitIsNotFollowed() async throws {
        let window = TrashlessProbe.window()
        let gone = Self.hit("gone.txt")
        let kept = Self.hit("kept.txt")
        let disk = SnapshotDisk(holding: [gone, kept])
        let pane = try await Self.loadedPane(with: disk, in: window)
        let tab = try showing([gone, kept], in: pane)

        pane.runDelete([gone.path], permanent: true)
        await settle { names(tab) == ["kept.txt"] }
        #expect(names(tab) == ["kept.txt"])
        #expect(tab.departedSearchHits.isEmpty)

        disk.putBack(gone)
        pane.refreshCurrentDirectory()
        try await holdOutTheDeletePasses()
        #expect(names(tab) == ["kept.txt"])
    }

    /// Only what was deleted goes: a hit whose delete failed is still on disk and keeps its row.
    @Test("a hit that could not be deleted keeps its row")
    func failedHitKeepsItsRow() async throws {
        let window = TrashlessProbe.window()
        let backend = RefusingBackend(refusal: .permissionDenied)
        let pane = try await Self.loadedPane(with: backend, in: window)
        let hit = TrashlessProbe.file("t.txt")
        let tab = try showing([hit], in: pane)

        pane.runDelete([hit.path], permanent: false)

        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the failure was never reported")
        #expect(TrashlessProbe.isFailureReport(sheet))
        #expect(names(tab) == ["t.txt"])
        try #require(TrashlessProbe.defaultButton(in: sheet)).performClick(nil)
    }

    /// The question is about the file, not the tab the key was pressed in: every results tab
    /// holding the hit loses it, in front or behind, and a folder tab — which re-lists itself — is
    /// left alone even when its row is the same file.
    @Test("every results tab holding the hit loses it, and a folder tab does not")
    func dropsFromEveryResultsTab() {
        let pane = Self.compositePane([Self.hit("a.txt"), Self.hit("b.txt")])
        let first = pane.tabs[0]
        let second = PanelTab(panel: Self.results([Self.hit("a.txt")]))
        let folder = PanelTab(panel: Self.results([Self.hit("a.txt")], at: Self.documents))
        pane.tabs += [second, folder]
        pane.activeTabIndex = 2

        pane.noteSearchHitsDeleted([Self.hit("a.txt").path], permanent: false)

        #expect(names(first) == ["b.txt"])
        #expect(names(second).isEmpty)
        #expect(names(folder) == ["a.txt"])
    }

    /// The narrowness control: a listing that re-lists or re-gathers itself is left to do so, and
    /// a hand edit here would race it.
    @Test("a listing that can refresh itself is left alone")
    func leavesRefreshableListingsAlone() {
        for path in [
            Self.documents,
            VFSPath(backend: .trash, path: "/Trash"),
            VFSPath(backend: .icloud, path: "/iCloud Drive")
        ] {
            let pane = Self.compositePane([])
            pane.panel = Self.results([Self.hit("a.txt")], at: path)
            pane.noteSearchHitsDeleted([Self.hit("a.txt").path], permanent: false)
            #expect(names(pane.tabs[0]) == ["a.txt"], "\(path.backend)")
            #expect(pane.tabs[0].departedSearchHits.isEmpty, "\(path.backend)")
        }
    }

    /// New hits are a new snapshot, and what the old one lost to the Trash is not theirs to bring
    /// back.
    @Test("an edited search forgets what the old hits lost")
    func newHitsForgetTrashed() {
        let pane = Self.compositePane([Self.hit("a.txt")])
        let tab = pane.tabs[0]
        pane.noteSearchHitsDeleted([Self.hit("a.txt").path], permanent: false)
        #expect(!tab.departedSearchHits.isEmpty)

        pane.record(
            PanelViewController.ResultsPresentation(
                pathSummary: "Results",
                sort: FileSort(key: .name),
                query: FileQuery(nameContains: "b"),
                scope: nil,
                title: nil
            ),
            on: tab
        )

        #expect(tab.departedSearchHits.isEmpty)
    }
}

/// A disk the test can put things back on: a delete takes a path off it, and ⌘Z is the test putting
/// the entry back. `stat` answers from what is on it, which is what the pane's reconcile reads.
final class SnapshotDisk: VFSBackend, @unchecked Sendable {
    let id = VFSBackendID.local
    let capabilities: VFSCapabilities = [.read, .write, .trash]

    private let lock = NSLock()
    private var entries: [VFSPath: FileEntry]

    init(holding entries: [FileEntry]) {
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    }

    func putBack(_ entry: FileEntry) {
        lock.withLock { entries[entry.path] = entry }
    }

    func take(_ path: VFSPath) {
        _ = lock.withLock { entries.removeValue(forKey: path) }
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry {
        guard let entry = lock.withLock({ entries[path] }) else { throw VFSError.notFound(path) }
        return entry
    }

    func trashItem(at path: VFSPath) throws -> VFSPath? {
        take(path)
        return .local("/.Trash/\(path.lastComponent)")
    }

    func removeItem(at path: VFSPath) throws {
        take(path)
    }
}
