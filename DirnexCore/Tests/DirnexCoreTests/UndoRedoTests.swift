import Foundation
import Testing

@testable import DirnexCore

/// Redo — the inverse of the inverse (PLAN.md §M2 "Undo journal"). The governing property is
/// `op + undo + redo == op`: reverting a record undoes an operation, and reverting its
/// `inverted` redoes it, so the tree lands exactly where the operation first left it. The
/// executor is shared with undo (`UndoJournal.revert`), so these tests pin the round-trips and
/// the redo-stack bookkeeping that undo's suite doesn't touch.
@Suite("UndoRedo")
struct UndoRedoTests {
    let backend = LocalBackend()

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try backend.stat(at: tree.vfsPath(relative))
    }

    private func contents(_ tree: TempTree, _ relative: String) throws -> String {
        try String(contentsOfFile: tree.path(relative), encoding: .utf8)
    }

    /// A recursive relative-path → contents map of a subtree, for whole-tree comparison.
    private func snapshot(_ backend: any VFSBackend, under path: VFSPath) -> [String: String] {
        var result: [String: String] = [:]
        let base = path.path
        func walk(_ dir: VFSPath) {
            let entries = ((try? backend.listDirectory(at: dir)) ?? []).sorted { $0.name < $1.name }
            for entry in entries {
                let rel = String(entry.path.path.dropFirst(base.count))
                if entry.kind == .directory {
                    result[rel + "/"] = "<dir>"
                    walk(entry.path)
                } else {
                    result[rel] = (try? String(contentsOfFile: entry.path.path, encoding: .utf8)) ?? "<x>"
                }
            }
        }
        walk(path)
        return result
    }

    // MARK: - op + undo + redo == op

    @Test("redo re-applies a move after it was undone")
    func redoMove() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid")
        try tree.writeFile("top/a.txt", contents: "a")
        try tree.writeFile("top/mid/b.txt", contents: "b")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .move,
            sources: [try stat(tree, "top")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let record = try #require(
            UndoRecord.transfer(kind: .move, outcomes: CopyEngine.run(op, using: backend).outcomes)
        )
        let afterOp = snapshot(backend, under: tree.vfsPath())

        #expect(UndoJournal.revert(record, using: backend).succeeded) // undo
        #expect(UndoJournal.revert(record.inverted, using: backend).succeeded) // redo
        #expect(snapshot(backend, under: tree.vfsPath()) == afterOp) // right back to post-move
    }

    @Test("redo re-creates a copy after it was undone")
    func redoCopy() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "hello")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let record = try #require(
            UndoRecord.transfer(kind: .copy, outcomes: CopyEngine.run(op, using: backend).outcomes)
        )

        #expect(UndoJournal.revert(record, using: backend).succeeded) // undo: copy gone
        #expect(throws: VFSError.notFound(tree.vfsPath("dest/a.txt"))) { try stat(tree, "dest/a.txt") }
        #expect(UndoJournal.revert(record.inverted, using: backend).succeeded) // redo: copy back
        #expect(try contents(tree, "dest/a.txt") == "hello")
        #expect(try contents(tree, "a.txt") == "hello") // original still there
    }

    @Test("redo reproduces a keep-both copy's exact renamed landing path")
    func redoKeepBothCopy() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "fresh")
        try tree.makeDir("dest")
        try tree.writeFile("dest/a.txt", contents: "already here") // forces keep-both

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let record = try #require(
            UndoRecord.transfer(
                kind: .copy,
                outcomes: CopyEngine.run(op, using: backend, conflictPolicy: .keepBoth).outcomes
            )
        )
        let landed = try #require(record.steps.first.flatMap { step -> VFSPath? in
            if case let .removeCopy(_, copy) = step { return copy } else { return nil }
        })
        #expect(landed != tree.vfsPath("dest/a.txt")) // it took a fresh name

        #expect(UndoJournal.revert(record, using: backend).succeeded) // undo removes the keep-both copy
        #expect(UndoJournal.revert(record.inverted, using: backend).succeeded) // redo
        #expect(try contents(tree, "dest/a.txt") == "already here") // the pre-existing file untouched
        #expect((try? backend.stat(at: landed)) != nil) // the copy is back at its exact old name
    }

    @Test("redo re-creates a New Folder after it was undone")
    func redoNewFolder() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try backend.createDirectory(at: tree.vfsPath("fresh"))

        let record = UndoRecord.newFolder(at: tree.vfsPath("fresh"))
        #expect(UndoJournal.revert(record, using: backend).succeeded) // undo: folder removed
        #expect(throws: VFSError.notFound(tree.vfsPath("fresh"))) { try stat(tree, "fresh") }
        #expect(UndoJournal.revert(record.inverted, using: backend).succeeded) // redo: folder back
        #expect(try stat(tree, "fresh").kind == .directory)
    }

    @Test("redo restores a rename to the new name")
    func redoRename() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("old.txt", contents: "keep")
        try backend.moveItem(at: tree.vfsPath("old.txt"), to: tree.vfsPath("new.txt"))

        let record = UndoRecord.rename(from: tree.vfsPath("old.txt"), to: tree.vfsPath("new.txt"))
        #expect(UndoJournal.revert(record, using: backend).succeeded) // undo → old.txt
        #expect(UndoJournal.revert(record.inverted, using: backend).succeeded) // redo → new.txt
        #expect(try contents(tree, "new.txt") == "keep")
        #expect(throws: VFSError.notFound(tree.vfsPath("old.txt"))) { try stat(tree, "old.txt") }
    }

    @Test("redo of New Folder refuses to clobber something now at the path")
    func redoNewFolderRefusesClobber() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try backend.createDirectory(at: tree.vfsPath("fresh"))
        let record = UndoRecord.newFolder(at: tree.vfsPath("fresh"))
        #expect(UndoJournal.revert(record, using: backend).succeeded) // undo removes it
        try tree.writeFile("fresh", contents: "a file now sits here") // user recreates as a file

        let report = UndoJournal.revert(record.inverted, using: backend) // redo
        #expect(!report.succeeded)
        #expect(report.failures.first?.error == .alreadyExists(tree.vfsPath("fresh")))
        #expect(try contents(tree, "fresh") == "a file now sits here") // untouched
    }

    // MARK: - Redo-stack semantics

    @Test("undo moves an action onto redo; a fresh action clears redo")
    func redoStackTransitions() {
        var journal = UndoJournal()
        journal.record(.newFolder(at: .local("/a")))
        #expect(journal.canUndo && !journal.canRedo)

        let undone = journal.takeForUndo()
        #expect(undone?.steps == [.removeCreatedFolder(.local("/a"))])
        #expect(!journal.canUndo && journal.canRedo)
        // The redo entry is the inverse: it re-creates the folder.
        #expect(journal.redoTop?.steps == [.createFolder(.local("/a"))])

        // Redo brings it back to the undo stack, inverted again to the original.
        let redone = journal.takeForRedo()
        #expect(redone?.steps == [.createFolder(.local("/a"))])
        #expect(journal.canUndo && !journal.canRedo)
        #expect(journal.top?.steps == [.removeCreatedFolder(.local("/a"))])

        // A brand-new operation wipes any pending redo.
        _ = journal.takeForUndo() // stage a redo
        #expect(journal.canRedo)
        journal.record(.newFolder(at: .local("/b")))
        #expect(!journal.canRedo)
    }

    @Test("both stacks round-trip through JSON so redo survives relaunch")
    func redoCodableRoundTrip() throws {
        var journal = UndoJournal()
        journal.record(.rename(from: .local("/d/old"), to: .local("/d/new")))
        _ = journal.takeForUndo() // now empty undo, one redo entry

        let undo = try JSONEncoder().encode(journal.records)
        let redo = try JSONEncoder().encode(journal.redoRecords)
        let restored = UndoJournal(
            records: try JSONDecoder().decode([UndoRecord].self, from: undo),
            redoRecords: try JSONDecoder().decode([UndoRecord].self, from: redo)
        )
        #expect(restored.records == journal.records)
        #expect(restored.redoRecords == journal.redoRecords)
        #expect(restored.canRedo)
    }
}
