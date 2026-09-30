import Foundation
import Testing

@testable import DirnexCore

/// `Panel.cursorDirectory` — the directory a "create something here" command lands in.
///
/// A flat list has only one answer and always did; a tree draws several directories at once, so the
/// same question resolves to the folder the cursor's *row* lives in. Its own suite because
/// `PanelTreeTests` sits at SwiftLint's `type_body_length` ceiling, and because this is a concept
/// rather than another tree behavior.
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

    // MARK: - A merged listing

    /// iCloud Drive's merge built the way the app gathers it (`PanelViewController+ICloud`): the
    /// CloudDocs container's own children plus a `libraryRow` for the Pages app's `Documents` folder,
    /// installed at the synthetic merged path. It is the shape where "the row's parent" and "the
    /// pane's own directory" part company at the root level, since no two of its rows need share a
    /// parent and none of those parents is a folder the pane shows.
    private struct MergedTree {
        let temp: TempTree
        var panel: Panel
        let cloudDocs: VFSPath
        let documents: VFSPath

        init() throws {
            temp = try TempTree()
            let backend = LocalBackend()
            let docs = "Library/Mobile Documents/com~apple~CloudDocs"
            try temp.makeDir("\(docs)/Projects")
            try temp.writeFile("\(docs)/Projects/plan.md", bytes: 1)
            try temp.writeFile("\(docs)/notes.txt", bytes: 1)
            try ICloudFixture.makeContainer(
                temp,
                bundleID: "com.apple.Pages",
                name: "Pages",
                public: true,
                contents: ["Letter.pages"]
            )
            let library = try #require(
                ICloudDrive.appLibraries(home: temp.root.path, languageCode: nil).libraries.first
            )
            cloudDocs = temp.vfsPath(docs)
            documents = library.documents
            let row = try ICloudDrive.libraryRow(for: library, stat: backend.stat(at: documents))
            let merged = try ICloudDrive.merge(
                looseFiles: backend.listDirectory(at: cloudDocs),
                libraryRows: [row]
            )

            panel = Panel(path: ICloudLocation.mergedPath, sort: FileSort(key: .name))
            panel.setListing(DirectoryListing(path: ICloudLocation.mergedPath, entries: merged))
            panel.enterTreeMode()
            try panel.setTreeChildListing(documents, entries: backend.listDirectory(at: documents))
            let projects = cloudDocs.appending("Projects")
            try panel.setTreeChildListing(projects, entries: backend.listDirectory(at: projects))
        }
    }

    /// The bug, seen live 2026-09-16: F7 on a loose row offered «Create a folder in
    /// “com~apple~CloudDocs”», and on an app library's row would have created beside `Documents`,
    /// inside the app's container, somewhere iCloud Drive does not show.
    @Test("a root-level row of a merged listing answers the pane's own directory")
    func mergedRootLevelAnswersThePane() throws {
        var merged = try MergedTree()
        defer { merged.temp.cleanup() }
        #expect(rowNames(merged.panel) == ["Pages", "Projects", "notes.txt"])
        // The rows really do live in two different directories, neither of them the pane's.
        let parents = Set(merged.panel.displayedEntries.compactMap(\.path.parent))
        #expect(parents == [try #require(merged.documents.parent), merged.cloudDocs])

        for index in 0..<merged.panel.count {
            merged.panel.moveCursor(to: index)
            let row = rowNames(merged.panel)[index]
            #expect(merged.panel.cursorDirectory == ICloudLocation.mergedPath, "\(row)")
        }
    }

    /// The narrowness control: a row a child listing put there lives where its path says, inside an
    /// app library and inside a loose folder alike. Without it, "always answer the pane" passes the
    /// test above and creates every deeper item at the root.
    @Test("a deeper row inside a merged listing still answers its own folder")
    func mergedDeeperLevelAnswersTheFolder() throws {
        var merged = try MergedTree()
        defer { merged.temp.cleanup() }
        let projects = merged.cloudDocs.appending("Projects")
        merged.panel.expand(merged.documents)
        merged.panel.expand(projects)
        #expect(
            rowNames(merged.panel) == ["Pages", "Letter.pages", "Projects", "plan.md", "notes.txt"]
        )

        merged.panel.moveCursor(to: 1)
        #expect(merged.panel.cursorDirectory == merged.documents)
        merged.panel.moveCursor(to: 3)
        #expect(merged.panel.cursorDirectory == projects)
        // And back up at the root level the pane answers again, between two expanded folders.
        merged.panel.moveCursor(to: 2)
        #expect(merged.panel.cursorDirectory == ICloudLocation.mergedPath)
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
