import Foundation
import Testing

@testable import DirnexCore

@Suite("Panel")
struct PanelTests {
    private func entry(_ name: String, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: .local("/dir/\(name)"),
            name: name,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: name.hasPrefix("."),
            permissions: 0o644,
            inode: 0
        )
    }

    private func listing(_ names: [String], at path: String = "/dir") -> DirectoryListing {
        DirectoryListing(path: .local(path), entries: names.map { entry($0) })
    }

    private func panel(_ names: [String], sort: FileSort = .default) -> Panel {
        Panel(model: DirectoryModel(listing: listing(names), sort: sort))
    }

    private let flatSort = FileSort(key: .name, ascending: true, directoriesFirst: false)

    // MARK: - Cursor

    @Test("cursor clamps within bounds")
    func cursorClamps() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 99)
        #expect(subject.cursor == 2)
        subject.moveCursor(to: -5)
        #expect(subject.cursor == 0)
        subject.moveCursor(by: 1)
        #expect(subject.cursor == 1)
    }

    @Test("currentEntry follows the cursor")
    func currentEntryFollowsCursor() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 1)
        #expect(subject.currentEntry?.name == "b")
    }

    @Test("empty panel has no current entry and cursor stays at 0")
    func emptyPanel() {
        var subject = panel([])
        #expect(subject.currentEntry == nil)
        subject.moveCursor(to: 5)
        #expect(subject.cursor == 0)
    }

    // MARK: - Selection independent of cursor

    @Test("marking does not move the cursor")
    func markingKeepsCursor() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 1)
        subject.toggleMark(at: 2)
        #expect(subject.cursor == 1)
        #expect(subject.isMarked(subject.model[2]))
    }

    @Test("toggle at cursor then advance marks a run")
    func markRun() {
        var subject = panel(["a", "b", "c", "d"], sort: flatSort)
        subject.toggleMarkAtCursorAndAdvance() // marks a, cursor -> b
        subject.toggleMarkAtCursorAndAdvance() // marks b, cursor -> c
        #expect(subject.cursor == 2)
        #expect(subject.selectedEntries.map(\.name) == ["a", "b"])
    }

    @Test("toggle removes an existing mark")
    func toggleRemoves() {
        var subject = panel(["a", "b"], sort: flatSort)
        subject.toggleMark(at: 0)
        subject.toggleMark(at: 0)
        #expect(subject.selectionCount == 0)
    }

    @Test("select all, invert, and clear")
    func selectAllInvertClear() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.selectAll()
        #expect(subject.selectionCount == 3)
        subject.invertSelection()
        #expect(subject.selectionCount == 0)
        subject.toggleMark(at: 1)
        subject.invertSelection()
        #expect(subject.selectedEntries.map(\.name) == ["a", "c"])
        subject.clearSelection()
        #expect(subject.selectionCount == 0)
    }

    // MARK: - Mouse (Finder-style) selection

    @Test("toggleMarkMovingCursor flips a mark and moves the cursor")
    func toggleMarkMovesCursor() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.toggleMarkMovingCursor(to: 1)
        #expect(subject.selectedEntries.map(\.name) == ["b"])
        #expect(subject.cursor == 1)
        subject.toggleMarkMovingCursor(to: 1)
        #expect(subject.selectionCount == 0)
        #expect(subject.cursor == 1)
    }

    @Test("selectRange marks the inclusive run and unions onto the base")
    func selectRangeUnionsBase() {
        var subject = panel(["a", "b", "c", "d", "e"], sort: flatSort)
        // Cmd-click a and d, then Shift-click from d back through b.
        subject.toggleMark(at: 0) // base carries "a"
        let base: Set<VFSPath> = subject.selection
        subject.selectRange(from: 3, through: 1, base: base)
        #expect(Set(subject.selectedEntries.map(\.name)) == ["a", "b", "c", "d"])
        #expect(subject.cursor == 1)
    }

    @Test("re-sweeping from the same anchor replaces the previous run but keeps the base")
    func selectRangeResweepReplaces() {
        var subject = panel(["a", "b", "c", "d", "e"], sort: flatSort)
        let base: Set<VFSPath> = [] // fresh plain click at index 1, no prior marks
        subject.selectRange(from: 1, through: 4, base: base) // b..e
        #expect(Set(subject.selectedEntries.map(\.name)) == ["b", "c", "d", "e"])
        subject.selectRange(from: 1, through: 2, base: base) // shrink to b..c
        #expect(Set(subject.selectedEntries.map(\.name)) == ["b", "c"])
    }

    @Test("selectRange clamps indices to the visible entries")
    func selectRangeClamps() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.selectRange(from: -5, through: 99, base: [])
        #expect(Set(subject.selectedEntries.map(\.name)) == ["a", "b", "c"])
        #expect(subject.cursor == 2)
    }

    // MARK: - Pattern (glob) selection

    @Test("selectMatching adds glob matches, deselectMatching removes them")
    func patternSelect() {
        var subject = panel(["a.txt", "b.txt", "c.jpg", "photo.JPG"], sort: flatSort)
        subject.selectMatching("*.txt")
        #expect(subject.selectedEntries.map(\.name) == ["a.txt", "b.txt"])

        subject.selectMatching("*.jpg") // case-insensitive: matches both .jpg and .JPG
        #expect(Set(subject.selectedEntries.map(\.name)) == ["a.txt", "b.txt", "c.jpg", "photo.JPG"])

        subject.deselectMatching("*.txt")
        #expect(Set(subject.selectedEntries.map(\.name)) == ["c.jpg", "photo.JPG"])
    }

    // MARK: - Navigation & refresh

    @Test("navigating to a new directory resets cursor and clears selection")
    func navigationResets() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 2)
        subject.selectAll()

        subject.setListing(listing(["x", "y"], at: "/other"))
        #expect(subject.path == .local("/other"))
        #expect(subject.cursor == 0)
        #expect(subject.selectionCount == 0)
    }

    @Test("same-directory refresh keeps the cursor on the same entry by identity")
    func refreshPreservesCursorByIdentity() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 1) // on "b"
        #expect(subject.currentEntry?.name == "b")

        // A file appears before "b"; row index would shift, identity must not.
        subject.setListing(listing(["a", "aa", "b", "c"], at: "/dir"))
        #expect(subject.currentEntry?.name == "b")
        #expect(subject.cursor == 2)
    }

    @Test("refresh prunes marks for vanished entries but keeps the rest")
    func refreshPrunesSelection() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.selectAll() // a, b, c

        subject.setListing(listing(["a", "c"], at: "/dir")) // b deleted
        #expect(Set(subject.selectedEntries.map(\.name)) == ["a", "c"])
    }

    @Test("refresh clamps cursor when the current entry disappears")
    func refreshClampsCursor() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 2) // on "c"
        subject.setListing(listing(["a", "b"], at: "/dir")) // c deleted
        #expect(subject.cursor == 1)
    }

    // MARK: - setModel (off-main pre-sorted install — PLAN.md §M7 perf pass)

    /// The off-main sort path hands `Panel` a fully-materialised `DirectoryModel` via `setModel`
    /// instead of a raw listing via `setListing`. These pin that it reconciles cursor and marks
    /// exactly as `setListing` does — the same refresh-vs-navigation decision, by the model's path.
    private func model(_ names: [String], at path: String = "/dir") -> DirectoryModel {
        DirectoryModel(listing: listing(names, at: path), sort: flatSort)
    }

    @Test("setModel to a new directory resets cursor and clears selection")
    func setModelNavigationResets() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 2)
        subject.selectAll()

        subject.setModel(model(["x", "y"], at: "/other"))
        #expect(subject.path == .local("/other"))
        #expect(subject.cursor == 0)
        #expect(subject.selectionCount == 0)
    }

    @Test("setModel same-directory refresh keeps the cursor on the same entry by identity")
    func setModelRefreshPreservesCursorByIdentity() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 1) // on "b"

        subject.setModel(model(["a", "aa", "b", "c"])) // a file appears before "b"
        #expect(subject.currentEntry?.name == "b")
        #expect(subject.cursor == 2)
    }

    @Test("setModel prunes marks for vanished entries but keeps the rest")
    func setModelRefreshPrunesSelection() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.selectAll() // a, b, c

        subject.setModel(model(["a", "c"])) // b deleted
        #expect(Set(subject.selectedEntries.map(\.name)) == ["a", "c"])
    }

    @Test("setModel installs the model's own sort without re-sorting")
    func setModelInstallsPreSortedOrder() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        // A model sorted the other way is installed verbatim — the pane adopts its order.
        let descending = DirectoryModel(
            listing: listing(["a", "b", "c"]),
            sort: FileSort(key: .name, ascending: false, directoriesFirst: false)
        )
        subject.setModel(descending)
        #expect(subject.model.visibleEntries.map(\.name) == ["c", "b", "a"])
    }

    // MARK: - View settings preserve cursor

    @Test("changing sort keeps the cursor on the same entry")
    func sortPreservesCursor() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 0) // on "a"
        subject.setSort(FileSort(key: .name, ascending: false, directoriesFirst: false))
        #expect(subject.currentEntry?.name == "a") // now last row
        #expect(subject.cursor == 2)
    }

    @Test("filtering out the current entry clamps the cursor")
    func filterClampsCursor() {
        var subject = panel(["apple", "banana", "cherry"], sort: flatSort)
        subject.moveCursor(to: 1) // on "banana"
        subject.setFilter("a") // matches apple, banana
        #expect(subject.currentEntry?.name == "banana")
        subject.setFilter("cherry") // banana gone; only cherry remains
        #expect(subject.currentEntry?.name == "cherry")
        #expect(subject.cursor == 0)
    }

    // MARK: - Open targets

    @Test("openTarget navigates into directories but not files")
    func openTargets() throws {
        let entries = [entry("file.txt"), entry("folder", kind: .directory)]
        let subject = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: .local("/dir"), entries: entries),
            sort: flatSort
        ))
        let file = try #require(subject.model.visibleEntries.first { $0.name == "file.txt" })
        let folder = try #require(subject.model.visibleEntries.first { $0.name == "folder" })
        #expect(subject.openTarget(for: file) == nil)
        #expect(subject.openTarget(for: folder) == .local("/dir/folder"))
    }

    @Test("parentPath is the containing directory")
    func parentPath() {
        let subject = panel(["a"], sort: flatSort)
        #expect(subject.parentPath == .local("/"))
    }
}
