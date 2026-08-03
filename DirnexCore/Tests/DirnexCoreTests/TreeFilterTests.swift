import Foundation
import Testing

@testable import DirnexCore

/// How the type-to-filter behaves in a tree — split from `TreeProjectionTests` (which was at
/// SwiftLint's `type_body_length` ceiling) along the seam the rule itself draws: matching a level is
/// `DirectoryModel`'s job and is covered there, while deciding whether a **non-matching folder**
/// survives as the way to a match is the one rule the tree adds of its own.
///
/// Covers that rule at both levels it surfaces — the `TreeProjection` that implements it and the
/// `Panel` facade the app reads it through — because the reporting half (`matchCount`) is only
/// meaningful as the two compared, and a test that pins one without the other would not notice the
/// facade handing back the wrong mode's answer.
@Suite("Tree filter")
struct TreeFilterTests {
    /// A `FileEntry` under `dir`; tests override only what they assert on. Private per suite, the way
    /// every other tree suite here carries its own.
    private func entry(
        _ name: String,
        in dir: VFSPath = .local("/root"),
        kind: FileEntry.Kind = .file,
        size: Int64 = 1,
        hidden: Bool = false
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
            symlinkDestination: nil,
            symlinkTargetKind: nil
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

    @Test("an expanded folder that doesn't match survives when a descendant does")
    func filterKeepsAncestorsOfMatches() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), entry("notes.txt")])
        tree.setListing(docs, entries: [entry("report.pdf", in: docs), entry("other.log", in: docs)])
        tree.expand(docs)

        // Nothing here is called "report" except the file itself — the folder on the way to it is
        // kept as scaffolding, which is the whole point of filtering a tree.
        tree.filter = "report"
        #expect(shape(tree).map { "\($0.0)@\($0.1)" } == ["docs@0", "report.pdf@1"])
    }

    @Test("scaffolding is kept through several non-matching levels")
    func filterKeepsWholeAncestorChain() {
        let outer = root.appending("outer")
        let inner = outer.appending("inner")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("outer"), entry("z.txt")])
        tree.setListing(outer, entries: [dir("inner", in: outer), entry("y.txt", in: outer)])
        tree.setListing(inner, entries: [entry("needle.txt", in: inner), entry("x.txt", in: inner)])
        tree.expand(outer)
        tree.expand(inner)

        tree.filter = "needle"
        #expect(shape(tree).map { "\($0.0)@\($0.1)" } == ["outer@0", "inner@1", "needle.txt@2"])
    }

    @Test("an expanded folder with no matching descendant filters out")
    func filterDropsFolderWithNoMatchAnywhere() {
        let docs = root.appending("docs")
        let keep = root.appending("keep")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), dir("keep")])
        tree.setListing(docs, entries: [entry("a.txt", in: docs)])
        tree.setListing(keep, entries: [entry("needle.txt", in: keep)])
        tree.expand(docs)
        tree.expand(keep)

        // `docs` neither matches nor leads anywhere: scaffolding is earned, not automatic.
        tree.filter = "needle"
        #expect(shape(tree).map { "\($0.0)@\($0.1)" } == ["keep@0", "needle.txt@1"])
    }

    @Test("a collapsed folder rescues nothing, even holding a listing with a match")
    func filterIgnoresCollapsedFolders() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs")])
        tree.setListing(docs, entries: [entry("needle.txt", in: docs)])
        tree.expand(docs)
        tree.filter = "needle"
        #expect(shape(tree).map(\.0) == ["docs", "needle.txt"])

        // Collapsing takes the match off screen, so the folder has nothing left to stand for. The
        // filter projects the rows in hand; it never reaches into a folder the user closed.
        tree.collapse(docs)
        #expect(tree.isEmpty)
    }

    @Test("a hidden descendant rescues its ancestor only when hidden entries are shown")
    func filterAncestorRescueRespectsShowHidden() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name), showHidden: false)
        tree.setListing(root, entries: [dir("docs")])
        tree.setListing(docs, entries: [entry(".needle", in: docs, hidden: true)])
        tree.expand(docs)

        tree.filter = "needle"
        #expect(tree.isEmpty)

        tree.showHidden = true
        #expect(shape(tree).map(\.0) == ["docs", ".needle"])
    }

    @Test("clearing the filter restores every row, scaffolding and all")
    func filterClearingRestoresTheTree() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), entry("z.txt")])
        tree.setListing(docs, entries: [entry("report.pdf", in: docs), entry("other.log", in: docs)])
        tree.expand(docs)
        let unfiltered = shape(tree).map { "\($0.0)@\($0.1)" }

        tree.filter = "report"
        #expect(shape(tree).count == 2)
        tree.filter = ""
        #expect(shape(tree).map { "\($0.0)@\($0.1)" } == unfiltered)
    }

    // MARK: - Match count (what the status line reports)

    @Test("matchCount counts matches only, not the folders kept as the path to them")
    func matchCountExcludesScaffolding() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), entry("toplevel.txt")])
        tree.setListing(docs, entries: [
            entry("report-a.pdf", in: docs),
            entry("report-b.pdf", in: docs),
            entry("other.log", in: docs)
        ])
        tree.expand(docs)

        tree.filter = "report"
        // Three rows on screen — `docs` plus its two matches — but only two things were found.
        #expect(tree.count == 3)
        #expect(tree.matchCount == 2)
        #expect(tree.rows.map(\.matchesFilter) == [false, true, true])
    }

    @Test("a folder that matches on its own name counts as a match")
    func matchCountIncludesMatchingFolders() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs")])
        tree.setListing(
            docs,
            entries: [entry("doc-one.txt", in: docs), entry("other.log", in: docs)]
        )
        tree.expand(docs)

        // `docs` is a result here, not scaffolding — it is what the user typed.
        tree.filter = "doc"
        #expect(tree.count == 2)
        #expect(tree.matchCount == 2)
        // Hoisted: `allSatisfy` inside `#expect` doesn't compile (NOTES.md ▸ Testing).
        let everyRowMatched = tree.rows.allSatisfy(\.matchesFilter)
        #expect(everyRowMatched)
    }

    @Test("with no filter every row is a match, so matchCount is the row count")
    func matchCountEqualsCountUnfiltered() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs"), entry("z.txt")])
        tree.setListing(docs, entries: [entry("a.txt", in: docs)])
        tree.expand(docs)

        #expect(tree.count == 3)
        #expect(tree.matchCount == 3)

        // And it comes back when the filter is cleared, rather than sticking at the narrowed value.
        tree.filter = "a.txt"
        #expect(tree.matchCount == 1)
        tree.filter = ""
        #expect(tree.matchCount == 3)
    }

    @Test("matchCount tracks a collapse that removes the scaffolding it was hiding")
    func matchCountTracksCollapse() {
        let docs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [dir("docs")])
        tree.setListing(docs, entries: [entry("needle.txt", in: docs)])
        tree.expand(docs)
        tree.filter = "needle"
        #expect(tree.count == 2)
        #expect(tree.matchCount == 1)

        tree.collapse(docs)
        #expect(tree.isEmpty)
        #expect(tree.matchCount == 0)
    }

    // MARK: - Match count across both modes

    @Test("matchCount is the row count in a list and drops the scaffolding in a tree")
    func matchCountAcrossModes() {
        let docs = root.appending("docs")
        var panel = Panel(path: root, sort: FileSort(key: .name))
        panel.setListing(DirectoryListing(path: root, entries: [dir("docs"), entry("z.txt")]))

        // Flat: every visible row matched by construction, filtered or not.
        #expect(panel.matchCount == panel.count)
        panel.setFilter("z")
        #expect(panel.matchCount == 1)
        #expect(panel.matchCount == panel.count)
        panel.setFilter("")

        panel.enterTreeMode()
        panel.setTreeChildListing(docs, entries: [entry("report.pdf", in: docs)])
        panel.expand(docs)
        #expect(panel.matchCount == panel.count)

        // `docs` is now on screen only as the way to `report.pdf`, so the two part company.
        panel.setFilter("report")
        #expect(panel.count == 2)
        #expect(panel.matchCount == 1)

        // Leaving the tree hands the question back to the flat model.
        panel.exitTreeMode()
        #expect(panel.matchCount == panel.count)
    }
}
