import Foundation
import Testing

@testable import DirnexCore

/// `SizeVisualization` over a `TreeProjection` (PLAN.md §M15, size bars re-scoped per level): each
/// row is measured against its **own parent directory**, so an expanded folder's children compare
/// among themselves rather than against the whole tree. The flat-listing behaviour is pinned in
/// `SizeVisualizationTests`; this suite is only the per-level story.
@Suite("SizeVisualization — tree")
struct SizeVisualizationTreeTests {
    private let root = VFSPath.local("/test")

    /// A `FileEntry` under `dir`, so a child's path reflects its real parent — which is what
    /// `SizeVisualization(tree:)` groups on.
    private func entry(
        _ name: String,
        in dir: VFSPath,
        kind: FileEntry.Kind = .file,
        size: Int64 = 0
    ) -> FileEntry {
        FileEntry(
            path: dir.appending(name),
            name: name,
            kind: kind,
            byteSize: size,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil
        )
    }

    @Test("a tree scales each row against its own parent directory, not the whole projection")
    func perParentDenominators() throws {
        // root: A (dir, 100) and B (dir, 200); B is expanded and holds b1=30, b2=70.
        let dirA = root.appending("A")
        let dirB = root.appending("B")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [
            entry("A", in: root, kind: .directory),
            entry("B", in: root, kind: .directory)
        ])
        tree.setListing(dirB, entries: [
            entry("b1.bin", in: dirB, size: 30),
            entry("b2.bin", in: dirB, size: 70)
        ])
        tree.expand(dirB)
        // Root folders are sized by the scan; B is the heavier.
        tree.setDirectorySizes([dirA: 100, dirB: 200])

        let viz = SizeVisualization(tree: tree)

        // Root level (A, B) — scaled against each other: B fills the bar, A is half.
        let barA = try #require(viz.bar(for: entry("A", in: root, kind: .directory)))
        let barB = try #require(viz.bar(for: entry("B", in: root, kind: .directory)))
        #expect(barB.fraction == 1.0)
        #expect(barA.fraction == 100.0 / 200.0)
        #expect(barA.share == 100.0 / 300.0)
        #expect(barB.share == 200.0 / 300.0)

        // B's children — a *different* group: b2 fills the bar against b1, and shares are of B's own
        // total (100), not the root's 300. This is the whole point of per-level scoping.
        let barB1 = try #require(viz.bar(for: entry("b1.bin", in: dirB, size: 30)))
        let barB2 = try #require(viz.bar(for: entry("b2.bin", in: dirB, size: 70)))
        #expect(barB2.fraction == 1.0)
        #expect(barB1.fraction == 30.0 / 70.0)
        #expect(barB1.share == 30.0 / 100.0)
        #expect(barB2.share == 70.0 / 100.0)

        // The scalar figures describe the primary (root) group only.
        #expect(viz.maximumBytes == 200)
        #expect(viz.totalBytes == 300)
    }

    @Test("an all-collapsed tree draws exactly the flat model's bars")
    func allCollapsedMatchesFlat() {
        let entries = [
            entry("a.bin", in: root, size: 100),
            entry("b.bin", in: root, size: 300),
            entry("c.bin", in: root, size: 200)
        ]
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: entries)

        let treeViz = SizeVisualization(tree: tree)
        let flatViz = SizeVisualization(model: DirectoryModel(
            listing: DirectoryListing(path: root, entries: entries),
            sort: FileSort(key: .name)
        ))

        for row in entries {
            #expect(treeViz.bar(for: row)?.fraction == flatViz.bar(for: row)?.fraction)
            #expect(treeViz.bar(for: row)?.share == flatViz.bar(for: row)?.share)
        }
        #expect(treeViz.maximumBytes == flatViz.maximumBytes)
        #expect(treeViz.totalBytes == flatViz.totalBytes)
    }

    @Test("pending directories span every expanded level, in display order")
    func pendingSpansLevels() {
        let dirDocs = root.appending("docs")
        let dirSub = dirDocs.appending("sub")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [
            entry("docs", in: root, kind: .directory),
            entry("z.txt", in: root, size: 10)
        ])
        tree.setListing(dirDocs, entries: [
            entry("sub", in: dirDocs, kind: .directory),
            entry("a.txt", in: dirDocs, size: 5)
        ])
        tree.expand(dirDocs)
        tree.setListing(dirSub, entries: [entry("deep.txt", in: dirSub, size: 1)])
        tree.expand(dirSub)

        let viz = SizeVisualization(tree: tree)
        // Unsized directories at every level, depth-first in display order.
        #expect(viz.pendingDirectories.map(\.name) == ["docs", "sub"])
        // Files everywhere already have a bar; a directory only once walked.
        #expect(viz.bar(for: entry("deep.txt", in: dirSub, size: 1)) != nil)
        #expect(viz.bar(for: entry("docs", in: root, kind: .directory)) == nil)
    }

    @Test("a folder the rule excludes leaves no trace at its own level")
    func exclusionPerLevel() {
        let dirDocs = root.appending("docs")
        var tree = TreeProjection(rootPath: root, sort: FileSort(key: .name))
        tree.setListing(root, entries: [entry("docs", in: root, kind: .directory)])
        tree.setListing(dirDocs, entries: [
            entry("keep.txt", in: dirDocs, size: 100),
            entry("build", in: dirDocs, kind: .directory)
        ])
        tree.expand(dirDocs)

        let viz = SizeVisualization(tree: tree) { $0.lastComponent == "build" }
        // The excluded folder is neither pending nor sized nor part of docs' denominator.
        #expect(viz.pendingDirectories.map(\.name) == ["docs"])
        #expect(viz.bar(for: entry("build", in: dirDocs, kind: .directory)) == nil)
        #expect(viz.bar(for: entry("keep.txt", in: dirDocs, size: 100))?.share == 1.0)
    }
}
