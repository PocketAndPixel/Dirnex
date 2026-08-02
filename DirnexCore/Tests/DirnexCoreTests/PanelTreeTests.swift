import Foundation
import Testing

@testable import DirnexCore

/// `Panel` in tree mode (PLAN.md §M15 Slice 4): the tree is the row source, marks span levels, and
/// the cursor stays on the same entry by identity across expand/collapse and refresh.
@Suite("Panel — tree mode")
struct PanelTreeTests {
    private let root = VFSPath.local("/root")

    private func entry(
        _ name: String,
        in dir: VFSPath = .local("/root"),
        kind: FileEntry.Kind = .file,
        hidden: Bool = false
    ) -> FileEntry {
        FileEntry(
            path: dir.appending(name),
            name: name,
            kind: kind,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            isHidden: hidden,
            permissions: 0o644,
            inode: 0
        )
    }

    private func dir(_ name: String, in parent: VFSPath = .local("/root")) -> FileEntry {
        entry(name, in: parent, kind: .directory)
    }

    /// A tree-mode panel rooted at `/root` with the given root entries, name-sorted.
    private func treePanel(_ rootEntries: [FileEntry]) -> Panel {
        var panel = Panel(path: root, sort: FileSort(key: .name))
        panel.setListing(DirectoryListing(path: root, entries: rootEntries))
        panel.enterTreeMode()
        return panel
    }

    private func rowNames(_ panel: Panel) -> [String] {
        panel.displayedEntries.map(\.name)
    }

    // MARK: - Entering / leaving

    @Test("entering tree mode with nothing expanded shows the same rows as the list")
    func enterMatchesList() {
        var panel = Panel(path: root, sort: FileSort(key: .name))
        panel.setListing(DirectoryListing(path: root, entries: [dir("b"), entry("a.txt")]))
        let listRows = panel.displayedEntries
        panel.enterTreeMode()

        #expect(panel.isTree)
        #expect(panel.displayedEntries == listRows)
        panel.exitTreeMode()
        #expect(!panel.isTree)
        #expect(panel.displayedEntries == listRows)
    }

    @Test("the cursor stays on the same entry entering and leaving tree mode")
    func modeSwitchPreservesCursor() {
        var panel = treePanel([dir("b"), entry("a.txt"), entry("c.txt")])
        panel.moveCursor(to: 2) // "c.txt"
        #expect(panel.currentEntry?.name == "c.txt")
        panel.exitTreeMode()
        #expect(panel.currentEntry?.name == "c.txt")
    }

    // MARK: - Expand / collapse

    @Test("expanding a folder inserts its children as panel rows")
    func expandAddsRows() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(
            docs,
            entries: [entry("a.txt", in: docs), entry("b.txt", in: docs)]
        )
        #expect(rowNames(panel) == ["docs", "z.txt"]) // not expanded yet

        panel.expand(docs)
        #expect(rowNames(panel) == ["docs", "a.txt", "b.txt", "z.txt"])
        #expect(panel.count == 4)
        #expect(panel.tree?.rows[1].depth == 1)
    }

    @Test("expanding a folder below the cursor does not move the cursor")
    func expandKeepsCursor() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs)])
        panel.moveCursor(to: 1) // "z.txt"
        #expect(panel.currentEntry?.name == "z.txt")

        panel.expand(docs) // inserts "a.txt" above "z.txt"
        #expect(panel.currentEntry?.name == "z.txt") // cursor followed the entry, not the index
        #expect(panel.cursor == 2)
    }

    @Test("collapsing keeps the cursor on a surviving entry")
    func collapseKeepsCursor() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs)])
        panel.expand(docs)
        panel.moveCursor(to: 2) // "z.txt"

        panel.collapse(docs)
        #expect(rowNames(panel) == ["docs", "z.txt"])
        #expect(panel.currentEntry?.name == "z.txt")
    }

    // MARK: - Marks span levels

    @Test("marks span levels and selectedEntries returns them in row order")
    func marksSpanLevels() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(
            docs,
            entries: [entry("a.txt", in: docs), entry("b.txt", in: docs)]
        )
        panel.expand(docs)

        // Mark a child (row 1) and a root file (row 3).
        panel.toggleMark(at: 1) // docs/a.txt
        panel.toggleMark(at: 3) // z.txt
        #expect(panel.selectionCount == 2)
        #expect(panel.selectedEntries.map(\.name) == ["a.txt", "z.txt"])
        #expect(panel.selection.contains(docs.appending("a.txt")))
    }

    @Test("select-all marks every visible row across levels")
    func selectAllAcrossLevels() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs)])
        panel.expand(docs)

        panel.selectAll()
        #expect(panel.selectionCount == 3) // docs, docs/a.txt, z.txt
    }

    @Test("invert selection covers every level")
    func invertAcrossLevels() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs)])
        panel.expand(docs)
        panel.toggleMark(at: 1) // mark the child

        panel.invertSelection()
        #expect(Set(panel.selectedEntries.map(\.name)) == ["docs", "z.txt"])
    }

    @Test("selectRange marks an inclusive run spanning a level boundary")
    func rangeAcrossLevels() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(
            docs,
            entries: [entry("a.txt", in: docs), entry("b.txt", in: docs)]
        )
        panel.expand(docs) // rows: docs, a.txt, b.txt, z.txt

        panel.selectRange(from: 1, through: 3, base: [])
        #expect(panel.selectedEntries.map(\.name) == ["a.txt", "b.txt", "z.txt"])
        #expect(panel.cursor == 3)
    }

    // MARK: - Refresh preserves cross-level marks

    @Test("a root refresh keeps marks made in an expanded child")
    func rootRefreshKeepsChildMarks() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs)])
        panel.expand(docs)
        panel.toggleMark(at: 1) // docs/a.txt
        #expect(panel.selection.contains(docs.appending("a.txt")))

        // FSEvents refresh of the root (docs still present): the child mark must survive.
        panel.setListing(DirectoryListing(path: root, entries: [
            dir("docs"),
            entry("z.txt"),
            entry("new.txt")
        ]))
        #expect(panel.selection.contains(docs.appending("a.txt")))
        #expect(rowNames(panel).contains("new.txt"))
    }

    @Test("a folder vanishing from the root drops its rows and prunes its child marks")
    func vanishedFolderPrunesMarks() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs)])
        panel.expand(docs)
        panel.toggleMark(at: 1) // docs/a.txt

        // The child's stale listing is still held, so its id is still "present"; the row is gone
        // because its parent is, but the mark is only pruned once the child listing itself is dropped.
        panel.setListing(DirectoryListing(path: root, entries: [entry("z.txt")]))
        #expect(rowNames(panel) == ["z.txt"])
        #expect(panel.selection.contains(docs.appending("a.txt")))

        // Re-listing the (now childless) folder — how the app reflects a vanished subtree — prunes
        // the stranded mark, since its id is no longer among the tree's entries.
        panel.setTreeChildListing(docs, entries: [])
        #expect(!panel.selection.contains(docs.appending("a.txt")))
    }

    // MARK: - Navigation resets the tree

    @Test("navigating to a new directory resets the tree to all-collapsed")
    func navigationResetsTree() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs)])
        panel.expand(docs)
        #expect(panel.count == 3)

        let other = VFSPath.local("/other")
        panel.setListing(DirectoryListing(path: other, entries: [entry("x.txt", in: other)]))
        #expect(panel.isTree) // still tree mode
        #expect(rowNames(panel) == ["x.txt"]) // fresh root, nothing expanded
        #expect(panel.tree?.isExpanded(docs) == false)
    }

    // MARK: - Sort / hidden drive the tree

    @Test("changing sort re-orders every level")
    func sortDrivesTree() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs")])
        panel.setTreeChildListing(docs, entries: [
            entry("a.txt", in: docs),
            entry("c.txt", in: docs),
            entry("b.txt", in: docs)
        ])
        panel.expand(docs)
        #expect(rowNames(panel) == ["docs", "a.txt", "b.txt", "c.txt"])

        panel.setSort(FileSort(key: .name, ascending: false))
        #expect(rowNames(panel) == ["docs", "c.txt", "b.txt", "a.txt"])
    }

    @Test("show-hidden reveals hidden entries at every level")
    func hiddenDrivesTree() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs")])
        panel.setTreeChildListing(docs, entries: [
            entry("a.txt", in: docs),
            entry(".h", in: docs, hidden: true)
        ])
        panel.expand(docs)
        #expect(rowNames(panel) == ["docs", "a.txt"])

        panel.setShowHidden(true)
        #expect(rowNames(panel) == ["docs", ".h", "a.txt"])
    }

    // MARK: - One index space

    /// The row⇄entry mapping in both directions, which is what every mouse gesture and every
    /// cursor-restore goes through. Reaching past these into `model` is the fork that crashed a
    /// live click on the first tree row below the root's last entry (PLAN.md §M15 Slice 4).
    @Test("a display row maps to the entry the tree draws there, past the root's own count")
    func displayedEntryReadsTreeRows() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [
            entry("a.txt", in: docs),
            entry("b.txt", in: docs)
        ])
        panel.expand(docs)
        #expect(rowNames(panel) == ["docs", "a.txt", "b.txt", "z.txt"])
        // Row 3 exists in the tree and is past the end of the two-entry root model.
        #expect(panel.count == 4)
        #expect(panel.displayedEntry(at: 3)?.name == "z.txt")
        #expect(panel.displayedEntry(at: 4) == nil)
    }

    @Test("an entry's display row is its tree row, and nil for one that isn't shown")
    func displayedIndexReadsTreeRows() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs)])
        panel.expand(docs)

        #expect(panel.displayedIndex(ofID: docs.appending("a.txt")) == 1)
        #expect(panel.displayedIndex(ofID: root.appending("z.txt")) == 2)
        #expect(panel.displayedIndex(ofID: root.appending("nope.txt")) == nil)

        // Collapsed, the child is no longer a row — and `z.txt` moves back up to 1.
        panel.collapse(docs)
        #expect(panel.displayedIndex(ofID: docs.appending("a.txt")) == nil)
        #expect(panel.displayedIndex(ofID: root.appending("z.txt")) == 1)
    }

    @Test("in list mode both accessors are the flat model's")
    func indexSpaceMatchesModelInListMode() {
        var panel = Panel(path: root, sort: FileSort(key: .name))
        panel.setListing(DirectoryListing(path: root, entries: [dir("docs"), entry("z.txt")]))
        #expect(panel.displayedIndex(ofID: root.appending("z.txt")) == panel.model.index(
            ofID: root.appending("z.txt")
        ))
        #expect(panel.displayedEntry(at: 1) == panel.model[1])
    }
}
