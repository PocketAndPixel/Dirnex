import Foundation
import Testing

@testable import DirnexCore

/// The order a batch of renames runs in, and the order its undo and redo run in (2026-11-05).
///
/// The on-disk tests are the claim: a tree selection holding a folder and a file inside it, renamed
/// through the real `LocalBackend` and reversed through the real journal. In the order a tree marks
/// them, folder first, the file's rename fails, which the first test shows rather than assumes.
@Suite("Multi-rename order")
struct MultiRenameOrderTests {
    private let backend = LocalBackend()

    // MARK: - The order

    @Test("deepest first, stable within one depth")
    func deepestFirst() {
        let paths = ["/docs", "/b.txt", "/docs/api/x.md", "/a.txt", "/docs/api", "/docs/c.txt"]
        #expect(
            RenameOrder.deepestFirst(paths) { $0 }
                == ["/docs/api/x.md", "/docs/api", "/docs/c.txt", "/docs", "/b.txt", "/a.txt"]
        )
    }

    /// A flat batch is every item at one depth, so it runs exactly as it always did.
    @Test("a flat batch keeps its order")
    func flatBatchUnchanged() {
        let paths = ["/c", "/a", "/b"]
        #expect(RenameOrder.deepestFirst(paths) { $0 } == paths)
    }

    /// The landing: the first item at the shallowest depth, so never a path a later rename moved.
    @Test("the cursor lands on the first of the shallowest items")
    func landing() {
        #expect(RenameOrder.shallowest(["/docs/b.txt", "/guides", "/z.txt"]) { $0 } == "/guides")
        #expect(RenameOrder.shallowest(["/c", "/a"]) { $0 } == "/c")
        #expect(RenameOrder.shallowest([String]()) { $0 } == nil)
    }

    // MARK: - On disk

    /// The bug, measured: in the order a tree marks them the folder goes first, and the file inside
    /// it is then not where its rename looks.
    @Test("in marked order, the file inside a renamed folder is not found")
    func markedOrderFails() throws {
        let tree = try Self.tree()
        defer { tree.cleanup() }

        try backend.moveItem(at: tree.vfsPath("docs"), to: tree.vfsPath("guides"))
        #expect(throws: VFSError.self) {
            try backend.moveItem(at: tree.vfsPath("docs/a.txt"), to: tree.vfsPath("docs/b.txt"))
        }
    }

    /// Apply deepest first, then undo and redo through the journal's own executor, and the tree is
    /// what it should be at every step. This is the property the undo journal owes every operation
    /// (op + undo == original), here for a batch whose order matters.
    @Test("a folder and its file: renamed, undone and redone")
    func renameUndoRedoRoundTrip() throws {
        let tree = try Self.tree()
        defer { tree.cleanup() }
        let marked: [(from: VFSPath, to: VFSPath)] = [
            (tree.vfsPath("docs"), tree.vfsPath("guides")),
            (tree.vfsPath("docs/a.txt"), tree.vfsPath("docs/b.txt"))
        ]

        var applied: [(original: VFSPath, renamed: VFSPath)] = []
        for job in RenameOrder.deepestFirst(marked, path: { $0.from.path }) {
            try backend.moveItem(at: job.from, to: job.to)
            applied.append((original: job.from, renamed: job.to))
        }
        #expect(try Self.files(in: tree) == ["guides/b.txt", "top.txt"])

        let record = try #require(UndoRecord.multiRename(applied))
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(try Self.files(in: tree) == ["docs/a.txt", "top.txt"])
        #expect(try String(contentsOfFile: tree.path("docs/a.txt"), encoding: .utf8) == "inside")

        // Redo is the inverted record through the same executor, and undoing again is the
        // inverted record's own inverse, which is the original record back.
        #expect(UndoJournal.revert(record.inverted, using: backend).succeeded)
        #expect(try Self.files(in: tree) == ["guides/b.txt", "top.txt"])
        #expect(record.inverted.inverted.steps == record.steps)
        #expect(UndoJournal.revert(record.inverted.inverted, using: backend).succeeded)
        #expect(try Self.files(in: tree) == ["docs/a.txt", "top.txt"])
    }

    // MARK: - Fixture

    /// `docs/a.txt` and `top.txt`.
    private static func tree() throws -> TempTree {
        let tree = try TempTree()
        try tree.makeDir("docs")
        try tree.writeFile("docs/a.txt", contents: "inside")
        try tree.writeFile("top.txt", contents: "top")
        return tree
    }

    /// Every regular file under the tree, relative and sorted.
    private static func files(in tree: TempTree) throws -> [String] {
        let enumerator = try #require(FileManager.default.enumerator(atPath: tree.root.path))
        var found: [String] = []
        while let relative = enumerator.nextObject() as? String {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: tree.path(relative), isDirectory: &isDirectory)
            if !isDirectory.boolValue { found.append(relative) }
        }
        return found.sorted()
    }
}
