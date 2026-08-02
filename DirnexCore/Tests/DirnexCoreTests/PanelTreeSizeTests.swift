import Foundation
import Testing

@testable import DirnexCore

/// `Panel`'s directory-total routing across the tree/list boundary (PLAN.md §M15, size bars re-scoped
/// per level). The size *math* lives in `SizeVisualizationTreeTests`; this suite pins where a total
/// is stored — the tree's cross-level map in tree mode, the flat model otherwise — and that it
/// survives the refreshes and mode switches that used to prune it.
@Suite("Panel — tree directory sizes")
struct PanelTreeSizeTests {
    private let root = VFSPath.local("/root")

    private func entry(
        _ name: String,
        in dir: VFSPath = .local("/root"),
        kind: FileEntry.Kind = .file
    ) -> FileEntry {
        FileEntry(
            path: dir.appending(name),
            name: name,
            kind: kind,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    private func dir(_ name: String, in parent: VFSPath = .local("/root")) -> FileEntry {
        entry(name, in: parent, kind: .directory)
    }

    private func treePanel(_ rootEntries: [FileEntry]) -> Panel {
        var panel = Panel(path: root, sort: FileSort(key: .name))
        panel.setListing(DirectoryListing(path: root, entries: rootEntries))
        panel.enterTreeMode()
        return panel
    }

    @Test("a size set in tree mode reaches a child at any depth and survives a root refresh")
    func treeSizeSpansLevelsAndRefresh() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [dir("sub", in: docs), entry("a.txt", in: docs)])
        panel.expand(docs)
        let sub = docs.appending("sub")

        // Size a directory two levels down — it routes into the tree, not the flat root model.
        panel.setDirectorySize(sub, bytes: 4096)
        #expect(panel.computedSize(of: dir("sub", in: docs)) == 4096)
        // The flat model never heard of it: this is exactly the pruning that lost tree sizes before.
        #expect(panel.model.computedSize(of: dir("sub", in: docs)) == nil)

        // A root refresh (FSEvents) re-lists the root; the deep child's total must not be pruned away.
        panel.setListing(DirectoryListing(path: root, entries: [dir("docs"), entry("z.txt")]))
        #expect(panel.computedSize(of: dir("sub", in: docs)) == 4096)
    }

    @Test("leaving tree mode carries root-level totals back into the flat list")
    func exitTreePreservesRootSizes() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), dir("other")])
        panel.setTreeChildListing(docs, entries: [dir("sub", in: docs)])
        panel.expand(docs)

        panel.setDirectorySize(docs, bytes: 1000) // root-level folder
        panel.setDirectorySize(docs.appending("sub"), bytes: 500) // a deeper folder
        panel.exitTreeMode()

        // The root folder's total is now the list's; the deeper one has no row and is dropped.
        #expect(panel.computedSize(of: dir("docs")) == 1000)
        #expect(panel.model.computedSize(of: dir("docs")) == 1000)
        #expect(panel.model.directorySizes[docs.appending("sub")] == nil)
    }

    @Test("a size computed by hand before the tree opens carries into it")
    func listSizeSeedsTree() {
        var panel = Panel(path: root, sort: FileSort(key: .name))
        panel.setListing(DirectoryListing(path: root, entries: [dir("docs"), entry("z.txt")]))
        panel.setDirectorySize(root.appending("docs"), bytes: 2048) // in list mode → model
        panel.enterTreeMode()

        // `freshTree` seeds from the model, so the tree already knows it — no re-walk.
        #expect(panel.computedSize(of: dir("docs")) == 2048)
    }

    @Test("clearing totals in tree mode empties the tree's map, not the model's")
    func clearTreeSizes() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs")])
        panel.setTreeChildListing(docs, entries: [dir("sub", in: docs)])
        panel.expand(docs)
        panel.setDirectorySize(docs.appending("sub"), bytes: 512)
        #expect(panel.computedSize(of: dir("sub", in: docs)) == 512)

        panel.clearDirectorySizes()
        #expect(panel.computedSize(of: dir("sub", in: docs)) == nil)
    }
}
