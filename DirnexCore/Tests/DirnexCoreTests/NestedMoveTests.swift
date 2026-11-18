import Foundation
import Testing

@testable import DirnexCore

/// F2 with a name typed as a path (2026-11-18): `Archive/2025/report.pdf` moves the item below its
/// own folder, making the folders on the way, and one ⌘Z puts it back and removes them.
@Suite("NestedCreation: a move into a typed path")
struct NestedMoveTests {
    let backend = LocalBackend()

    private func text(_ tree: TempTree, _ relative: String) throws -> String {
        try String(contentsOfFile: tree.path(relative), encoding: .utf8)
    }

    private func exists(_ tree: TempTree, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: tree.path(relative))
    }

    @Test("the item moves below the folders it made, outermost first")
    func movesIntoNewFolders() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("report.pdf", contents: "pdf")

        let moved = try NestedCreation.move(
            tree.vfsPath("report.pdf"), to: tree.vfsPath("Archive/2025/report.pdf"), using: backend
        )

        #expect(moved == NestedCreation.Moved(
            folders: [tree.vfsPath("Archive"), tree.vfsPath("Archive/2025")], deferred: false
        ))
        #expect(try text(tree, "Archive/2025/report.pdf") == "pdf")
        #expect(!exists(tree, "report.pdf"))
    }

    @Test("a folder already there is used, and a new last name is taken on the way")
    func movesIntoAnExistingFolder() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("report.pdf", contents: "pdf")
        try tree.makeDir("Archive")

        let moved = try NestedCreation.move(
            tree.vfsPath("report.pdf"), to: tree.vfsPath("Archive/old report.pdf"), using: backend
        )

        #expect(moved.folders.isEmpty)
        #expect(try text(tree, "Archive/old report.pdf") == "pdf")
    }

    /// Every backend's `moveItem` replaces what is there, so the refusal is the move's own.
    @Test("an occupied target is refused, and both files keep their bytes")
    func refusesAnOccupiedTarget() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("report.pdf", contents: "new")
        try tree.makeDir("Archive")
        try tree.writeFile("Archive/report.pdf", contents: "old")

        #expect(throws: VFSError.alreadyExists(tree.vfsPath("Archive/report.pdf"))) {
            try NestedCreation.move(
                tree.vfsPath("report.pdf"), to: tree.vfsPath("Archive/report.pdf"), using: backend
            )
        }
        #expect(try text(tree, "report.pdf") == "new")
        #expect(try text(tree, "Archive/report.pdf") == "old")
    }

    @Test("a move that fails takes back the folders it made, and the item stays")
    func failureTakesBack() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("report.pdf", contents: "pdf")
        let tooLong = String(repeating: "n", count: 300)

        #expect(throws: VFSError.self) {
            try NestedCreation.move(
                tree.vfsPath("report.pdf"), to: tree.vfsPath("Archive/\(tooLong)"), using: backend
            )
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: tree.root.path) == ["report.pdf"]
        )
    }

    /// An S3 prefix answers `EXDEV`, and the copy-then-delete job that finishes it copies into the
    /// folders, so they stay; nothing has moved yet.
    @Test("a move the backend sends the long way keeps its folders and says so")
    func deferredKeepsTheFolders() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("prefix")
        let backend = CrossDeviceBackend()

        let moved = try NestedCreation.move(
            tree.vfsPath("prefix"), to: tree.vfsPath("Archive/prefix"), using: backend
        )

        #expect(moved == NestedCreation.Moved(folders: [tree.vfsPath("Archive")], deferred: true))
        #expect(exists(tree, "Archive"))
        #expect(exists(tree, "prefix"))
    }

    @Test("one undo puts the item back and removes the folders; redo does it all again")
    func undoAndRedo() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("report.pdf", contents: "pdf")
        let source = tree.vfsPath("report.pdf")
        let target = tree.vfsPath("Archive/2025/report.pdf")
        let moved = try NestedCreation.move(source, to: target, using: backend)
        let record = UndoRecord.rename(from: source, to: target, madeFolders: moved.folders)

        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: tree.root.path) == ["report.pdf"]
        )

        #expect(UndoJournal.revert(record.inverted, using: backend).succeeded)
        #expect(try text(tree, "Archive/2025/report.pdf") == "pdf")
        #expect(!exists(tree, "report.pdf"))
    }

    @Test("a plain rename's record is unchanged")
    func plainRenameRecord() {
        let record = UndoRecord.rename(from: .local("/a/old"), to: .local("/a/new"))
        #expect(record.steps == [.restore(from: .local("/a/new"), to: .local("/a/old"))])
    }

    // MARK: - Inside an archive

    private static func name(_ typed: String) throws -> NestedName {
        try NestedName(parsing: typed, as: .file)
    }

    @Test("a member's typed path lands below the member's own folder")
    func archiveInnerPath() throws {
        #expect(
            try ArchiveMutation.movedInnerPath(
                ofInnerPath: "/docs/a.txt",
                to: Self.name("Archive/2025/b.txt")
            )
                == "/docs/Archive/2025/b.txt"
        )
        #expect(
            try ArchiveMutation.movedInnerPath(ofInnerPath: "/a.txt", to: Self.name("sub/a.txt"))
                == "/sub/a.txt"
        )
    }

    @Test("a member folder moved into itself, or onto its own path, is refused")
    func archiveIntoItself() throws {
        #expect(
            try ArchiveMutation.movedInnerPath(ofInnerPath: "/docs", to: Self.name("docs/inner")) == nil
        )
        #expect(
            try ArchiveMutation.movedInnerPath(ofInnerPath: "/docs", to: Self.name("docs")) == nil
        )
        // A sibling whose name begins with the folder's is not inside it.
        #expect(
            try ArchiveMutation.movedInnerPath(ofInnerPath: "/docs", to: Self.name("docs2/docs"))
                == "/docs2/docs"
        )
    }

    @Test("the staged move makes the folders on the way and lands the member")
    func archiveStagesTheFolders() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "member")
        let archive = "/Users/tester/fixture.zip"

        try ArchiveMutation.stage(
            [ArchiveMutation.Move(from: "/a.txt", to: "/Archive/2025/a.txt")],
            ofArchiveAt: archive,
            inWorkingDirectory: tree.root.path
        )

        #expect(try text(tree, "Archive/2025/a.txt") == "member")
        #expect(!exists(tree, "a.txt"))
    }
}

/// A local backend whose `moveItem` answers `EXDEV`, as an S3 prefix rename does.
private struct CrossDeviceBackend: VFSBackend {
    private let local = LocalBackend()
    var id: VFSBackendID { local.id }
    var capabilities: VFSCapabilities { local.capabilities }
    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try local.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try local.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try local.createDirectory(at: path) }
    func removeItem(at path: VFSPath) throws { try local.removeItem(at: path) }
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        throw VFSError.io(path: source, code: EXDEV)
    }
}
