import Foundation
import Testing

@testable import DirnexCore

/// The active indent guide (PLAN.md §M15 Slice 4) — which vertical line a tree draws stronger for
/// the row under the cursor or the pointer, and how far down it runs.
@Suite("TreeIndentGuide")
struct TreeIndentGuideTests {
    private let root = VFSPath.local("/root")

    private func entry(_ name: String, in dir: VFSPath, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: dir.appending(name),
            name: name,
            kind: kind,
            byteSize: kind == .directory ? 0 : 1,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    private func dir(_ name: String, in parent: VFSPath) -> FileEntry {
        entry(name, in: parent, kind: .directory)
    }

    /// The tree the assertions below read, matching the shape in the report that asked for this:
    ///
    /// ```
    /// 0  docs/          depth 0, expanded
    /// 1    guide/       depth 1, expanded
    /// 2      deep.txt   depth 2
    /// 3    a.txt        depth 1
    /// 4  notes/         depth 0, collapsed
    /// 5  z.txt          depth 0
    /// ```
    private func sampleTree() -> TreeProjection {
        let docs = root.appending("docs")
        let guide = docs.appending("guide")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [
            dir("docs", in: root),
            dir("notes", in: root),
            entry("z.txt", in: root)
        ])
        tree.setListing(docs, entries: [dir("guide", in: docs), entry("a.txt", in: docs)])
        tree.setListing(guide, entries: [entry("deep.txt", in: guide)])
        tree.expand(docs)
        tree.expand(guide)
        return tree
    }

    @Test("the sample tree has the shape the rest of these tests read")
    func sampleShape() {
        let shape = sampleTree().rows.map { "\($0.entry.name)@\($0.depth)" }
        #expect(shape == ["docs@0", "guide@1", "deep.txt@2", "a.txt@1", "notes@0", "z.txt@0"])
    }

    // MARK: - Which line

    @Test("an open folder highlights the guide its own children stand beside")
    func openFolderHighlightsItsChildren() {
        // Row 0 is `docs`, open: its children are rows 1…3, and they draw their level-0 guide.
        #expect(sampleTree().activeGuide(forRow: 0) == TreeIndentGuide(level: 0, rows: 1..<4))
    }

    @Test("a file highlights the guide of the folder it is in, not its own level")
    func fileHighlightsItsParent() {
        // Row 3 is `a.txt` at depth 1, inside `docs` — the same line `docs` itself highlights.
        #expect(sampleTree().activeGuide(forRow: 3) == TreeIndentGuide(level: 0, rows: 1..<4))
        // Row 2 is `deep.txt` at depth 2, inside `guide` — one level in.
        #expect(sampleTree().activeGuide(forRow: 2) == TreeIndentGuide(level: 1, rows: 2..<3))
    }

    @Test("an open folder inside another highlights its children, not its siblings")
    func nestedOpenFolder() {
        // Row 1 is `guide`, open and itself at depth 1: the line it highlights is its *children's*
        // (level 1), which is the one thing that separates an open folder from a closed one here.
        #expect(sampleTree().activeGuide(forRow: 1) == TreeIndentGuide(level: 1, rows: 2..<3))
    }

    @Test("a closed folder behaves like a file — it highlights the folder it is in")
    func closedFolderHighlightsItsParent() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs", in: root)])
        tree.setListing(docs, entries: [dir("closed", in: docs), entry("a.txt", in: docs)])
        tree.expand(docs)

        // Row 1 is `closed`, a directory with a listing but *not* expanded.
        #expect(tree.rows[1].entry.name == "closed")
        #expect(tree.activeGuide(forRow: 1) == TreeIndentGuide(level: 0, rows: 1..<3))
    }

    // MARK: - How far it runs

    @Test("the run stops at the folder's last descendant, before a following sibling")
    func runStopsBeforeSibling() {
        let tree = sampleTree()
        let guide = tree.activeGuide(forRow: 0)
        // `notes` (row 4) and `z.txt` (row 5) are siblings of `docs`, not under it.
        #expect(guide?.rows.upperBound == 4)
        #expect(guide?.rows.contains(4) == false)
        // …and a grandchild two levels down *is* under it.
        #expect(guide?.rows.contains(2) == true)
    }

    @Test("the run never includes the folder's own row, which draws no line at that level")
    func runExcludesTheAnchor() {
        let tree = sampleTree()
        for row in tree.rows.indices {
            guard let guide = tree.activeGuide(forRow: row) else { continue }
            // Every highlighted row is deeper than the guide's level — the invariant that makes
            // "draw guides for 0..<depth" and "highlight level L" agree.
            for highlighted in guide.rows {
                #expect(tree.rows[highlighted].depth > guide.level)
            }
        }
    }

    // MARK: - Nothing to draw

    @Test("a depth-0 row has no guide of its own")
    func rootLevelHasNoGuide() {
        let tree = sampleTree()
        // `z.txt` — a depth-0 file.
        #expect(tree.activeGuide(forRow: 5) == nil)
        // `notes` — a depth-0 folder, closed, so it has no children on screen either.
        #expect(tree.activeGuide(forRow: 4) == nil)
    }

    @Test("an open folder with nothing under it has no line to highlight")
    func openButEmptyFolder() {
        let empty = root.appending("empty")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("empty", in: root)])
        tree.setListing(empty, entries: [])
        tree.expand(empty)

        #expect(tree.rows.count == 1)
        #expect(tree.activeGuide(forRow: 0) == nil)
    }

    @Test("an expanded folder still waiting for its listing has no line yet")
    func openButUnlistedFolder() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs", in: root)])
        tree.expand(docs) // the lazy-load window: expanded, no children yet

        #expect(tree.activeGuide(forRow: 0) == nil)
    }

    @Test("an out-of-range row answers nil rather than trapping")
    func outOfRange() {
        let tree = sampleTree()
        #expect(tree.activeGuide(forRow: -1) == nil)
        #expect(tree.activeGuide(forRow: tree.count) == nil)
        #expect(tree.activeGuide(forRow: 9999) == nil)
    }

    @Test("an empty projection answers nil for every row")
    func emptyProjection() {
        let tree = TreeProjection(rootPath: root)
        #expect(tree.activeGuide(forRow: 0) == nil)
    }

    // MARK: - Filtering

    @Test("a folder kept only as scaffolding still anchors the guide for the matches under it")
    func scaffoldingFolderAnchors() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs", in: root), entry("z.txt", in: root)])
        tree.setListing(docs, entries: [entry("report.pdf", in: docs), entry("other.txt", in: docs)])
        tree.expand(docs)
        tree.filter = "report"

        // `docs` survives only because a descendant matched; the guide is still its children's.
        #expect(tree.rows.map(\.entry.name) == ["docs", "report.pdf"])
        #expect(tree.activeGuide(forRow: 1) == TreeIndentGuide(level: 0, rows: 1..<2))
    }
}
