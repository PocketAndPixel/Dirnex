import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The cursor position and the marked files survive a relaunch (PLAN.md §M1 "restored on relaunch").
/// `PersistedTab` carries them as paths **relative to the tab's root** — identity-based, the same
/// anchoring the live cursor uses across a refresh, and the same spelling the tree's expansion uses —
/// and a restored tab re-applies them once its directory first lists (`applyPendingRestore`), dropping
/// anything that vanished since quit exactly as a live refresh prunes the cursor and marks.
///
/// A **tree** tab (PLAN.md §M15) is what makes the relative path earn its keep: its cursor can sit
/// inside an expanded folder, which a bare leaf name cannot address and which has no row to land on
/// until that folder's own listing arrives — so the re-apply runs again on each landing rather than
/// once at the root.
@Suite("Tab restoration: cursor and marks")
@MainActor
struct TabRestorationCursorTests {
    // MARK: - Fixtures

    private static func entry(
        _ name: String,
        in dir: String = "/dir",
        kind: FileEntry.Kind = .file
    ) -> FileEntry {
        FileEntry(
            path: .local("\(dir)/\(name)"),
            name: name,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    /// A pane with one tab whose panel lists `names` at `/dir`, ready to have pending restore state
    /// applied. Built headlessly (the view is never loaded), so it exercises `applyPendingRestore`
    /// without a window or an async directory load.
    private static func pane(listing names: [String]) -> PanelViewController {
        let vc = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: .local("/dir"),
            restorationKey: nil
        )
        let listing = DirectoryListing(path: .local("/dir"), entries: names.map { entry($0) })
        vc.panel = Panel(model: DirectoryModel(listing: listing))
        return vc
    }

    /// The same pane in tree mode, rooted at `/dir` over `sub/` + `a.txt`, with `sub` expanded but
    /// **not yet listed** — the state a restored tree is in between `restorePendingTreeExpansion`
    /// arming its lazy loads and those loads landing.
    private static func treePane() -> PanelViewController {
        let vc = pane(listing: [])
        let listing = DirectoryListing(
            path: .local("/dir"),
            entries: [entry("sub", kind: .directory), entry("a.txt")]
        )
        vc.panel = Panel(model: DirectoryModel(listing: listing))
        vc.tabs[0].viewMode = .tree
        vc.panel.enterTreeMode()
        vc.panel.expand(.local("/dir/sub"))
        return vc
    }

    /// `sub`'s listing arriving — what `loadTreeChild` installs.
    private static func landSubListing(in vc: PanelViewController) {
        vc.panel.setTreeChildListing(
            .local("/dir/sub"),
            entries: [entry("nested.txt", in: "/dir/sub")]
        )
    }

    // MARK: - Re-applying on first load

    @Test("a restored tab re-anchors its cursor on the same file and re-marks its selection")
    func reappliesCursorAndMarks() {
        let vc = Self.pane(listing: ["a.txt", "b.txt", "c.txt"])
        vc.tabs[0].pendingCursorPath = "b.txt"
        vc.tabs[0].pendingMarkPaths = ["a.txt", "c.txt"]

        vc.applyPendingRestore(toTab: 0)

        #expect(vc.panel.currentEntry?.name == "b.txt")
        #expect(vc.cursorOnParentRow == false)
        #expect(Set(vc.panel.selectedEntries.map(\.name)) == ["a.txt", "c.txt"])
        // One-shot: nothing to re-apply on the next navigation in this tab.
        #expect(vc.tabs[0].hasPendingRestore == false)
    }

    @Test("a cursor or mark on a file deleted since quit is silently dropped")
    func dropsVanishedNames() {
        let vc = Self.pane(listing: ["a.txt", "c.txt"]) // "b.txt" was deleted while the app was shut
        vc.tabs[0].pendingCursorPath = "b.txt"
        vc.tabs[0].pendingMarkPaths = ["a.txt", "b.txt", "c.txt"]

        vc.applyPendingRestore(toTab: 0)

        // The gone cursor target leaves the cursor at the top rather than jumping somewhere wrong…
        #expect(vc.panel.cursor == 0)
        // …and the gone mark is pruned, the surviving two kept.
        #expect(Set(vc.panel.selectedEntries.map(\.name)) == ["a.txt", "c.txt"])
        #expect(vc.tabs[0].hasPendingRestore == false)
    }

    @Test("a cursor parked on `..` is restored to `..`")
    func restoresParentRowCursor() {
        let vc = Self.pane(listing: ["a.txt", "b.txt"])
        vc.tabs[0].pendingCursorOnParent = true // no pendingCursorPath — the cursor was on `..`

        vc.applyPendingRestore(toTab: 0)

        #expect(vc.cursorOnParentRow == true)
        #expect(vc.tabs[0].pendingCursorOnParent == false)
    }

    @Test("a tab that was not restored from disk has nothing pending — apply is a no-op")
    func noPendingIsNoOp() {
        let vc = Self.pane(listing: ["a.txt", "b.txt", "c.txt"])
        vc.panel.moveCursor(to: 2)

        vc.applyPendingRestore(toTab: 0)

        #expect(vc.panel.cursor == 2) // untouched
        #expect(vc.panel.selectionCount == 0)
    }

    // MARK: - A tree's nested rows

    @Test("a cursor inside an expanded folder is anchored when that folder's listing lands")
    func anchorsCursorInsideExpandedFolder() {
        let vc = Self.treePane()
        vc.tabs[0].pendingCursorPath = "sub/nested.txt"
        vc.tabs[0].pendingMarkPaths = ["sub/nested.txt", "a.txt"]
        vc.tabs[0].pendingRestoreTreeLoads = 1 // `sub` is still being listed

        // The pass at the root can't reach a row that doesn't exist yet — and must not give up on it.
        vc.applyPendingRestore(toTab: 0)
        #expect(vc.tabs[0].pendingCursorPath == "sub/nested.txt")
        #expect(vc.tabs[0].pendingMarkPaths == ["sub/nested.txt"]) // the root-level mark did land
        #expect(vc.panel.cursor == 0)

        Self.landSubListing(in: vc)
        let anchored = vc.applyPendingRestore(toTab: 0)

        #expect(anchored)
        #expect(vc.panel.currentEntry?.name == "nested.txt")
        #expect(Set(vc.panel.selectedEntries.map(\.name)) == ["a.txt", "nested.txt"])
        #expect(vc.tabs[0].pendingCursorPath == nil)
        #expect(vc.tabs[0].pendingMarkPaths == nil)
    }

    @Test("what never resolves is dropped once the last restored listing has reported in")
    func closesRestoreWindowWhenLoadsFinish() {
        let vc = Self.treePane()
        vc.tabs[0].pendingCursorPath = "sub/gone.txt" // deleted while the app was shut
        vc.tabs[0].pendingRestoreTreeLoads = 1

        vc.applyPendingRestore(toTab: 0)
        #expect(vc.tabs[0].hasPendingRestore) // still waiting on `sub`

        Self.landSubListing(in: vc) // …which arrives without it
        vc.applyPendingRestore(toTab: 0)
        vc.finishRestoreTreeLoad(inTab: 0)

        #expect(vc.tabs[0].hasPendingRestore == false)
        #expect(vc.tabs[0].pendingRestoreTreeLoads == 0)
        #expect(vc.panel.cursor == 0) // left at the top, not somewhere wrong
    }

    @Test("a folder that fails to list still closes the window, so nothing stays pending forever")
    func failedListingClosesWindow() {
        let vc = Self.treePane()
        vc.tabs[0].pendingCursorPath = "sub/nested.txt"
        vc.tabs[0].pendingRestoreTreeLoads = 1

        vc.applyPendingRestore(toTab: 0)
        vc.finishRestoreTreeLoad(inTab: 0) // `loadTreeChild` reports in on every exit path

        #expect(vc.tabs[0].hasPendingRestore == false)
    }

    // MARK: - Writing to disk

    @Test("a tree tab persists its cursor and marks as paths relative to its root")
    func persistsNestedCursorRelativeToRoot() throws {
        let vc = Self.treePane()
        let key = "TabRestorationCursorTests-\(UUID().uuidString)"
        vc.restorationKey = key
        defer { UserDefaults.standard.removeObject(forKey: "Dirnex.tabs." + key) }
        Self.landSubListing(in: vc)
        let nested = try #require(vc.panel.displayedIndex(ofID: .local("/dir/sub/nested.txt")))
        vc.panel.moveCursor(to: nested)
        vc.panel.setSelection([.local("/dir/sub/nested.txt"), .local("/dir/a.txt")])

        vc.persistState()

        let pane = try #require(TabPersistence.load(paneKey: key))
        #expect(pane.tabs.first?.cursorPath == "sub/nested.txt")
        #expect(pane.tabs.first?.markedPaths == ["a.txt", "sub/nested.txt"])
        #expect(pane.tabs.first?.expandedPaths == ["sub"])
    }

    @Test("a flat list still persists a bare leaf name — a relative path with one component")
    func persistsFlatCursorAsLeafName() throws {
        let vc = Self.pane(listing: ["a.txt", "b.txt"])
        let key = "TabRestorationCursorTests-\(UUID().uuidString)"
        vc.restorationKey = key
        defer { UserDefaults.standard.removeObject(forKey: "Dirnex.tabs." + key) }
        vc.panel.moveCursor(to: 1)

        vc.persistState()

        let pane = try #require(TabPersistence.load(paneKey: key))
        #expect(pane.tabs.first?.cursorPath == "b.txt")
    }

    // MARK: - Seeding from disk

    @Test("restoredTabs seeds the cursor/marks pending state from the persisted tab")
    func seedsPendingFromPersistedTab() throws {
        // A real directory, so `restoredTabs` keeps the tab (it drops paths that no longer exist).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirnexCursorRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tab = PersistedTab(
            path: .local(dir.path),
            sort: .default,
            columns: nil,
            cursorPath: "notes.md",
            cursorOnParent: false,
            markedPaths: ["one.txt", "two.txt"]
        )
        let pane = PersistedPane(tabs: [tab], activeIndex: 0)

        let restored = PanelViewController.restoredTabs(from: pane)

        #expect(restored.count == 1)
        #expect(restored[0].pendingCursorPath == "notes.md")
        #expect(restored[0].pendingCursorOnParent == false)
        #expect(restored[0].pendingMarkPaths == ["one.txt", "two.txt"])
    }

    // MARK: - Backward compatibility

    @Test("tab state written before cursor/marks existed still decodes (missing keys → nil)")
    func decodesOldStateWithoutNewFields() throws {
        let legacy = """
        {"backend":"file","path":"/Users/x","sortKey":"name","sortAscending":true}
        """
        let tab = try JSONDecoder().decode(PersistedTab.self, from: Data(legacy.utf8))

        #expect(tab.cursorPath == nil)
        #expect(tab.cursorOnParent == nil)
        #expect(tab.markedPaths == nil)
    }
}
