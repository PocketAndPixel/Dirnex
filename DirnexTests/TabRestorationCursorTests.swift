import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The cursor position and the marked files survive a relaunch (PLAN.md §M1 "restored on relaunch").
/// `PersistedTab` carries them by *leaf name* — directory-relative and identity-based, the same
/// anchoring the live cursor uses across a refresh — and a restored tab re-applies them once its
/// directory first lists (`applyPendingRestore`), dropping anything that vanished since quit exactly
/// as a live refresh prunes the cursor and marks.
@Suite("Tab restoration: cursor and marks")
@MainActor
struct TabRestorationCursorTests {
    // MARK: - Fixtures

    private static func entry(_ name: String, in dir: String = "/dir") -> FileEntry {
        FileEntry(
            path: .local("\(dir)/\(name)"),
            name: name,
            kind: .file,
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

    // MARK: - Re-applying on first load

    @Test("a restored tab re-anchors its cursor on the same file and re-marks its selection")
    func reappliesCursorAndMarks() {
        let vc = Self.pane(listing: ["a.txt", "b.txt", "c.txt"])
        vc.tabs[0].pendingCursorName = "b.txt"
        vc.tabs[0].pendingMarkNames = ["a.txt", "c.txt"]

        vc.applyPendingRestore(toTab: 0)

        #expect(vc.panel.currentEntry?.name == "b.txt")
        #expect(vc.cursorOnParentRow == false)
        #expect(Set(vc.panel.selectedEntries.map(\.name)) == ["a.txt", "c.txt"])
        // One-shot: nothing to re-apply on the next navigation in this tab.
        #expect(vc.tabs[0].pendingCursorName == nil)
        #expect(vc.tabs[0].pendingMarkNames == nil)
    }

    @Test("a cursor or mark on a file deleted since quit is silently dropped")
    func dropsVanishedNames() {
        let vc = Self.pane(listing: ["a.txt", "c.txt"]) // "b.txt" was deleted while the app was shut
        vc.tabs[0].pendingCursorName = "b.txt"
        vc.tabs[0].pendingMarkNames = ["a.txt", "b.txt", "c.txt"]

        vc.applyPendingRestore(toTab: 0)

        // The gone cursor target leaves the cursor at the top rather than jumping somewhere wrong…
        #expect(vc.panel.cursor == 0)
        // …and the gone mark is pruned, the surviving two kept.
        #expect(Set(vc.panel.selectedEntries.map(\.name)) == ["a.txt", "c.txt"])
    }

    @Test("a cursor parked on `..` is restored to `..`")
    func restoresParentRowCursor() {
        let vc = Self.pane(listing: ["a.txt", "b.txt"])
        vc.tabs[0].pendingCursorOnParent = true // no pendingCursorName — the cursor was on `..`

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
            cursorName: "notes.md",
            cursorOnParent: false,
            markedNames: ["one.txt", "two.txt"]
        )
        let pane = PersistedPane(tabs: [tab], activeIndex: 0)

        let restored = PanelViewController.restoredTabs(from: pane)

        #expect(restored.count == 1)
        #expect(restored[0].pendingCursorName == "notes.md")
        #expect(restored[0].pendingCursorOnParent == false)
        #expect(restored[0].pendingMarkNames == ["one.txt", "two.txt"])
    }

    // MARK: - Backward compatibility

    @Test("tab state written before cursor/marks existed still decodes (missing keys → nil)")
    func decodesOldStateWithoutNewFields() throws {
        let legacy = """
        {"backend":"file","path":"/Users/x","sortKey":"name","sortAscending":true}
        """
        let tab = try JSONDecoder().decode(PersistedTab.self, from: Data(legacy.utf8))

        #expect(tab.cursorName == nil)
        #expect(tab.cursorOnParent == nil)
        #expect(tab.markedNames == nil)
    }
}
