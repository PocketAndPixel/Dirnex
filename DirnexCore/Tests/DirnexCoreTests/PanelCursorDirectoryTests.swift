import Foundation
import Testing

@testable import DirnexCore

/// `Panel.cursorDirectory` — the directory a "create something here" command lands in.
///
/// A flat list has only one answer and always did; a tree draws several directories at once, so the
/// same question resolves to the folder the cursor's *row* lives in. Its own suite because
/// `PanelTreeTests` sits at SwiftLint's `type_body_length` ceiling, and because this is a concept
/// rather than another tree behaviour.
@Suite("Panel — where a create lands")
struct PanelCursorDirectoryTests {
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

    private func rowNames(_ panel: Panel) -> [String] {
        panel.displayedEntries.map(\.name)
    }

    @Test("a flat list always creates into the pane's own directory")
    func flatListAlwaysAnswersTheRoot() {
        var panel = Panel(path: root, sort: FileSort(key: .name))
        panel.setListing(DirectoryListing(path: root, entries: [dir("docs"), entry("z.txt")]))
        #expect(panel.cursorDirectory == root)
        panel.moveCursor(to: 1)
        #expect(panel.cursorDirectory == root)
    }

    @Test("a cursor inside an expanded folder creates into that folder")
    func followsTheTreeLevel() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs), dir("sub", in: docs)])
        panel.expand(docs)
        #expect(rowNames(panel) == ["docs", "sub", "a.txt", "z.txt"]) // folders sort first

        // Row 0 is the folder itself — a sibling of `z.txt`, so it creates alongside it, not inside.
        #expect(panel.cursorDirectory == root)
        // A *folder* row answers with its parent too: the question is where the row lives.
        panel.moveCursor(to: 1) // "docs/sub"
        #expect(panel.cursorDirectory == docs)
        panel.moveCursor(to: 2) // "docs/a.txt"
        #expect(panel.cursorDirectory == docs)
        panel.moveCursor(to: 3) // "z.txt", back at root level
        #expect(panel.cursorDirectory == root)
    }

    @Test("three levels deep the target is the immediate parent, not the tree root")
    func answersTheImmediateParentAtDepth() {
        let docs = root.appending("docs")
        let deep = docs.appending("deep")
        var panel = treePanel([dir("docs")])
        panel.setTreeChildListing(docs, entries: [dir("deep", in: docs)])
        panel.setTreeChildListing(deep, entries: [entry("far.txt", in: deep)])
        panel.expand(docs)
        panel.expand(deep)
        #expect(rowNames(panel) == ["docs", "deep", "far.txt"])

        panel.moveCursor(to: 2)
        #expect(panel.cursorDirectory == deep)
    }

    @Test("collapsing the folder the cursor was in brings the target back to the root")
    func followsACollapse() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs)])
        panel.expand(docs)
        panel.moveCursor(to: 1)
        #expect(panel.cursorDirectory == docs)

        // The cursor's row is gone, so `Panel` keeps the index and lands on a root-level row.
        panel.collapse(docs)
        #expect(panel.currentEntry?.name == "z.txt")
        #expect(panel.cursorDirectory == root)
    }

    @Test("a scaffolding row is no different — the filter decides rows, not levels")
    func scaffoldingRowAnswersItsOwnLevel() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("report.pdf", in: docs)])
        panel.expand(docs)
        // "docs" survives only because something under it matches; it is still a root-level row.
        panel.setFilter("report")
        #expect(rowNames(panel) == ["docs", "report.pdf"])

        #expect(panel.cursorDirectory == root)
        panel.moveCursor(to: 1)
        #expect(panel.cursorDirectory == docs)
    }

    @Test("an empty tree has no row to read, so the target is the pane's own directory")
    func emptyTreeAnswersTheRoot() {
        let panel = treePanel([])
        #expect(panel.currentEntry == nil)
        #expect(panel.cursorDirectory == root)
    }

    @Test("leaving tree mode returns the target to the pane's own directory")
    func exitingTreeModeResets() {
        let docs = root.appending("docs")
        var panel = treePanel([dir("docs"), entry("z.txt")])
        panel.setTreeChildListing(docs, entries: [entry("a.txt", in: docs)])
        panel.expand(docs)
        panel.moveCursor(to: 1)
        #expect(panel.cursorDirectory == docs)

        panel.exitTreeMode()
        #expect(panel.cursorDirectory == root)
    }
}
