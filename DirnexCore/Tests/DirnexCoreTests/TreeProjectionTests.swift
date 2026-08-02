import Foundation
import Testing

@testable import DirnexCore

@Suite("TreeProjection")
struct TreeProjectionTests {
    /// A `FileEntry` under `dir`; tests override only what they assert on. A directory-like entry's
    /// own `byteSize` is irrelevant (the flat model treats it as 0 for size), so it defaults to 0.
    private func entry(
        _ name: String,
        in dir: VFSPath = .local("/root"),
        kind: FileEntry.Kind = .file,
        size: Int64 = 1,
        hidden: Bool = false,
        symlinkTargetKind: FileEntry.Kind? = nil
    ) -> FileEntry {
        FileEntry(
            path: dir.appending(name),
            name: name,
            kind: kind,
            byteSize: size,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            isHidden: hidden,
            permissions: 0o644,
            inode: 0,
            symlinkDestination: symlinkTargetKind != nil ? "/elsewhere" : nil,
            symlinkTargetKind: symlinkTargetKind
        )
    }

    private func dir(_ name: String, in parent: VFSPath = .local("/root")) -> FileEntry {
        entry(name, in: parent, kind: .directory, size: 0)
    }

    /// The row list as `(name, depth)` pairs — what every ordering assertion reads.
    private func shape(_ projection: TreeProjection) -> [(String, Int)] {
        projection.rows.map { ($0.entry.name, $0.depth) }
    }

    private let root = VFSPath.local("/root")

    // MARK: - The all-collapsed invariant

    @Test("with nothing expanded, the depth-0 rows are exactly the flat model's rows")
    func allCollapsedMatchesFlatModel() {
        let entries = [dir("Beta"), entry("alpha.txt"), dir("Alpha"), entry("beta.txt")]
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: entries)

        let flat = DirectoryModel(
            listing: DirectoryListing(path: root, entries: entries),
            sort: FileSort(key: .name)
        )

        #expect(tree.rows.map(\.entry) == flat.visibleEntries)
        #expect(tree.rows.allSatisfy { $0.depth == 0 })
        // Directories-first grouping still holds at the root level.
        #expect(shape(tree).map(\.0) == ["Alpha", "Beta", "alpha.txt", "beta.txt"])
    }

    @Test("an empty projection with no root listing has no rows")
    func emptyWithoutRootListing() {
        let tree = TreeProjection(rootPath: root)
        #expect(tree.isEmpty)
        #expect(tree.rows.isEmpty)
        #expect(tree.entry(at: 0) == nil)
    }

    // MARK: - Expand / collapse

    @Test("expanding a folder inserts its children at depth+1 right after it")
    func expandInsertsChildren() {
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), entry("z.txt")])
        tree.setListing(
            root.appending("docs"),
            entries: [
                entry("a.txt", in: root.appending("docs")),
                entry("b.txt", in: root.appending("docs"))
            ]
        )

        // Not shown until the folder is actually expanded.
        #expect(shape(tree).map(\.0) == ["docs", "z.txt"])

        tree.expand(root.appending("docs"))
        #expect(shape(tree).map { "\($0.0)@\($0.1)" } == ["docs@0", "a.txt@1", "b.txt@1", "z.txt@0"])
    }

    @Test("collapsing removes the children but keeps descendant expansion for re-open")
    func collapseKeepsDescendantExpansion() {
        let docs = root.appending("docs")
        let sub = docs.appending("sub")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs")])
        tree.setListing(docs, entries: [dir("sub", in: docs), entry("a.txt", in: docs)])
        tree.setListing(sub, entries: [entry("deep.txt", in: sub)])

        tree.expand(docs)
        tree.expand(sub)
        #expect(shape(tree).map(\.0) == ["docs", "sub", "deep.txt", "a.txt"])

        // Collapsing docs hides the whole subtree, sub included.
        tree.collapse(docs)
        #expect(shape(tree).map(\.0) == ["docs"])
        // …but sub is still remembered as expanded.
        #expect(tree.isExpanded(sub))

        // Re-expanding docs restores the sub-tree without re-expanding sub by hand.
        tree.expand(docs)
        #expect(shape(tree).map(\.0) == ["docs", "sub", "deep.txt", "a.txt"])
    }

    @Test("expanding a folder with no listing yet shows the folder but no children")
    func expandWithoutListingIsChildless() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), entry("z.txt")])

        tree.expand(docs)
        #expect(shape(tree).map(\.0) == ["docs", "z.txt"]) // lazy-load window: no children yet
        #expect(tree.isExpanded(docs))

        // The listing arriving later fills it in with no second expand call.
        tree.setListing(docs, entries: [entry("a.txt", in: docs)])
        #expect(shape(tree).map { "\($0.0)@\($0.1)" } == ["docs@0", "a.txt@1", "z.txt@0"])
    }

    // MARK: - Sort applies per level, not globally

    @Test("sort orders within each level rather than across the whole flattened list")
    func sortIsPerLevel() {
        // A name-ascending global sort would float the child "a.txt" above the root's "z.txt";
        // per-level, "a.txt" stays nested under its parent.
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), entry("z.txt")])
        tree.setListing(docs, entries: [entry("a.txt", in: docs)])
        tree.expand(docs)

        #expect(shape(tree).map { "\($0.0)@\($0.1)" } == ["docs@0", "a.txt@1", "z.txt@0"])
    }

    @Test("each level is independently sorted")
    func eachLevelSorted() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), entry("m.txt")])
        tree.setListing(docs, entries: [
            entry("c.txt", in: docs),
            entry("a.txt", in: docs),
            entry("b.txt", in: docs)
        ])
        tree.expand(docs)

        #expect(shape(tree).map(\.0) == ["docs", "a.txt", "b.txt", "c.txt", "m.txt"])
    }

    @Test("a sort change re-orders every level from the same source")
    func sortChangeReordersLevels() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name, ascending: true))
        tree.setListing(root, entries: [dir("docs")])
        tree.setListing(docs, entries: [
            entry("a.txt", in: docs),
            entry("c.txt", in: docs),
            entry("b.txt", in: docs)
        ])
        tree.expand(docs)
        #expect(shape(tree).map(\.0) == ["docs", "a.txt", "b.txt", "c.txt"])

        tree.sort = FileSort(key: .name, ascending: false)
        // Directories-first keeps "docs" on top; its children flip.
        #expect(shape(tree).map(\.0) == ["docs", "c.txt", "b.txt", "a.txt"])
    }

    // MARK: - A folder that vanishes while expanded

    @Test("a folder removed from its parent listing drops out, children and all")
    func vanishedFolderDropsOut() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), entry("z.txt")])
        tree.setListing(docs, entries: [entry("a.txt", in: docs)])
        tree.expand(docs)
        #expect(shape(tree).map(\.0) == ["docs", "a.txt", "z.txt"])

        // FSEvents refresh of the root: docs is gone. Its stale listing is now unreachable.
        tree.setListing(root, entries: [entry("z.txt")])
        #expect(shape(tree).map(\.0) == ["z.txt"])
        // Expansion state survives — re-creating docs (a folder made anew) re-shows its children.
        #expect(tree.isExpanded(docs))
        tree.setListing(root, entries: [dir("docs"), entry("z.txt")])
        #expect(shape(tree).map(\.0) == ["docs", "a.txt", "z.txt"])
    }

    // MARK: - Filter

    @Test("a filter that empties a level leaves the matching parent childless")
    func filterEmptiesALevel() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs")])
        tree.setListing(docs, entries: [entry("a.txt", in: docs), entry("b.txt", in: docs)])
        tree.expand(docs)

        // "docs" matches the filter at its own level; none of its children do.
        tree.filter = "doc"
        #expect(shape(tree).map(\.0) == ["docs"])
    }

    @Test("a filter removes non-matching entries at each level")
    func filterPerLevel() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        // Root has a matching file; the folder name also matches so it survives to show its children.
        tree.setListing(root, entries: [dir("docs"), entry("keep.txt"), entry("drop.log")])
        tree.setListing(
            docs,
            entries: [entry("dockeep.txt", in: docs), entry("other.log", in: docs)]
        )
        tree.expand(docs)

        tree.filter = "do" // matches "docs", "drop.log"? no — "drop.log" has no "do"… it has "dro".
        // "do" is a substring of "docs" and "dockeep.txt" only.
        #expect(shape(tree).map { "\($0.0)@\($0.1)" } == ["docs@0", "dockeep.txt@1"])
    }

    // MARK: - Hidden entries

    @Test("hidden entries are filtered per level, and showHidden reveals them")
    func hiddenPerLevel() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name), showHidden: false)
        tree.setListing(root, entries: [dir("docs"), entry(".secret", hidden: true)])
        tree.setListing(docs, entries: [
            entry("a.txt", in: docs),
            entry(".hidden", in: docs, hidden: true)
        ])
        tree.expand(docs)

        #expect(shape(tree).map(\.0) == ["docs", "a.txt"])

        tree.showHidden = true
        #expect(shape(tree).map(\.0) == ["docs", ".hidden", "a.txt", ".secret"])
    }

    // MARK: - Symlink-to-directory expansion, and deep nesting

    @Test("a symlink resolving to a directory can be expanded like a real folder")
    func symlinkDirectoryExpands() {
        let link = root.appending("link")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(
            root,
            entries: [entry("link", kind: .symlink, symlinkTargetKind: .directory)]
        )
        tree.setListing(link, entries: [entry("inside.txt", in: link)])
        tree.expand(link)

        #expect(shape(tree).map { "\($0.0)@\($0.1)" } == ["link@0", "inside.txt@1"])
    }

    @Test("three levels flatten depth-first with correct depths")
    func threeLevelsDepthFirst() {
        let dirA = root.appending("a")
        let dirB = dirA.appending("b")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("a"), entry("root.txt")])
        tree.setListing(dirA, entries: [dir("b", in: dirA), entry("a.txt", in: dirA)])
        tree.setListing(dirB, entries: [entry("b.txt", in: dirB)])
        tree.expand(dirA)
        tree.expand(dirB)

        #expect(shape(tree).map { "\($0.0)@\($0.1)" }
            == ["a@0", "b@1", "b.txt@2", "a.txt@1", "root.txt@0"])
    }

    // MARK: - Indexing

    @Test("index(ofID:) and entry(at:) address rows across levels")
    func indexingAcrossLevels() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), entry("z.txt")])
        tree.setListing(docs, entries: [entry("a.txt", in: docs)])
        tree.expand(docs)

        let child = docs.appending("a.txt")
        #expect(tree.index(ofID: child) == 1)
        #expect(tree.entry(at: 1)?.id == child)
        #expect(tree.index(ofID: root.appending("z.txt")) == 2)
        #expect(tree.index(ofID: root.appending("missing")) == nil)
    }
}
