import Foundation
import Testing

@testable import DirnexCore

/// The undo journal (PLAN.md §M2 "Undo journal correctness (the scariest feature) |
/// Property tests from M2 day one; non-reversible ops explicitly marked").
///
/// The core property is `op + undo == original tree`: run a real operation via the copy
/// engine (or a write primitive), reverse it through `UndoJournal.revert`, and assert the
/// tree is byte-for-byte what it was before. The rest pins the edges — overwrites marked
/// non-reversible, a folder the user has since filled left alone, a reoccupied destination
/// refused rather than clobbered, the stack's capacity, and the persistence round-trip.
@Suite("UndoJournal")
struct UndoJournalTests {
    let backend = LocalBackend()

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try backend.stat(at: tree.vfsPath(relative))
    }

    private func contents(_ tree: TempTree, _ relative: String) throws -> String {
        try String(contentsOfFile: tree.path(relative), encoding: .utf8)
    }

    /// A recursive relative-path → contents map of a subtree, for whole-tree comparison
    /// ("compare via content hash" — here exact contents, which is stronger for small trees).
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

    // MARK: - Copy

    @Test("undoing a copy removes the copy and leaves the original")
    func undoCopy() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "hello")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend)
        let record = try #require(UndoRecord.transfer(kind: .copy, outcomes: report.outcomes))

        #expect(try contents(tree, "dest/a.txt") == "hello")
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(throws: VFSError.notFound(tree.vfsPath("dest/a.txt"))) { try stat(tree, "dest/a.txt") }
        #expect(try contents(tree, "a.txt") == "hello") // original untouched
    }

    @Test("undoing a copied subtree removes the whole copy")
    func undoCopyTree() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid")
        try tree.writeFile("top/a.txt", contents: "a")
        try tree.writeFile("top/mid/b.txt", contents: "b")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "top")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let record = try #require(
            UndoRecord.transfer(kind: .copy, outcomes: CopyEngine.run(op, using: backend).outcomes)
        )

        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(throws: VFSError.notFound(tree.vfsPath("dest/top"))) { try stat(tree, "dest/top") }
        #expect(try contents(tree, "top/mid/b.txt") == "b") // source subtree intact
    }

    // MARK: - Move (the property test)

    @Test("op + undo == original tree, for a directory move")
    func undoMoveRestoresTree() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid")
        try tree.writeFile("top/a.txt", contents: "a")
        try tree.writeFile("top/mid/b.txt", contents: "b")
        try tree.makeDir("dest")

        let before = snapshot(backend, under: tree.vfsPath())

        let op = FileOperation(
            kind: .move,
            sources: [try stat(tree, "top")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let record = try #require(
            UndoRecord.transfer(kind: .move, outcomes: CopyEngine.run(op, using: backend).outcomes)
        )
        #expect(throws: VFSError.notFound(tree.vfsPath("top"))) { try stat(tree, "top") } // it did move

        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(snapshot(backend, under: tree.vfsPath()) == before) // and it came all the way back
    }

    @Test("a cross-volume move is undone by moving back through the engine")
    func undoCrossVolumeMove() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "ferry me back")
        try tree.makeDir("dest")

        let backend = CrossVolumeBackend()
        let op = FileOperation(
            kind: .move,
            sources: [try backend.stat(at: tree.vfsPath("a.txt"))],
            destinationDirectory: tree.vfsPath("dest")
        )
        let record = try #require(
            UndoRecord.transfer(kind: .move, outcomes: CopyEngine.run(op, using: backend).outcomes)
        )

        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(try contents(tree, "a.txt") == "ferry me back")
        #expect(throws: VFSError.notFound(tree.vfsPath("dest/a.txt"))) { try backend.stat(
            at: tree.vfsPath("dest/a.txt")
        ) }
    }

    // MARK: - Rename

    @Test("undoing a rename restores the old name")
    func undoRename() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("old.txt", contents: "keep")
        try backend.moveItem(at: tree.vfsPath("old.txt"), to: tree.vfsPath("new.txt"))

        let record = UndoRecord.rename(from: tree.vfsPath("old.txt"), to: tree.vfsPath("new.txt"))
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(try contents(tree, "old.txt") == "keep")
        #expect(throws: VFSError.notFound(tree.vfsPath("new.txt"))) { try stat(tree, "new.txt") }
    }

    // MARK: - New Folder

    @Test("undoing New Folder removes the empty folder")
    func undoNewFolderEmpty() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try backend.createDirectory(at: tree.vfsPath("fresh"))

        let record = UndoRecord.newFolder(at: tree.vfsPath("fresh"))
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(throws: VFSError.notFound(tree.vfsPath("fresh"))) { try stat(tree, "fresh") }
    }

    @Test("undoing New Folder leaves a folder the user has since filled")
    func undoNewFolderNonEmpty() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try backend.createDirectory(at: tree.vfsPath("fresh"))
        try tree.writeFile("fresh/added.txt", contents: "mine")

        let record = UndoRecord.newFolder(at: tree.vfsPath("fresh"))
        #expect(UndoJournal.revert(record, using: backend).succeeded) // no failure, just declines
        #expect(try contents(tree, "fresh/added.txt") == "mine") // data protected
    }

    // MARK: - Trash restore

    @Test("undoing a trash restores each item from its trash location")
    func undoTrashRestore() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("doc.txt", contents: "restore me")
        try tree.makeDir("trashcan")
        // Simulate a trash: the file now lives at its "trash location".
        try backend.moveItem(at: tree.vfsPath("doc.txt"), to: tree.vfsPath("trashcan/doc.txt"))

        let record = try #require(
            UndoRecord.trash(
                [(original: tree.vfsPath("doc.txt"), trashed: tree.vfsPath("trashcan/doc.txt"))]
            )
        )
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(try contents(tree, "doc.txt") == "restore me")
    }

    // MARK: - Non-reversible + skip handling in the builder

    @Test("an overwrite is counted non-reversible, not reversed")
    func overwriteIsNonReversible() {
        let src = VFSPath.local("/x/a.txt")
        let dst = VFSPath.local("/dest/a.txt")
        let outcomes = [
            OperationItemOutcome(
                source: VFSPath.local("/x/b.txt"),
                landedAt: VFSPath.local("/dest/b.txt"),
                replacedExisting: false
            ),
            OperationItemOutcome(source: src, landedAt: dst, replacedExisting: true)
        ]
        let record = UndoRecord.transfer(kind: .copy, outcomes: outcomes)
        #expect(record?.steps.count == 1) // only the clean copy is reversible
        #expect(record?.nonReversibleCount == 1)
        #expect(record?.steps.first == .removeCopy(
            source: VFSPath.local("/x/b.txt"),
            copy: VFSPath.local("/dest/b.txt")
        ))
    }

    @Test("a skipped item contributes no step, and an all-skip/all-overwrite op records nothing")
    func skippedAndUnreversibleProduceNoRecord() {
        let skipped = [
            OperationItemOutcome(source: .local("/x/a.txt"), landedAt: nil, replacedExisting: false)
        ]
        #expect(UndoRecord.transfer(kind: .copy, outcomes: skipped) == nil)

        let allOverwrite = [
            OperationItemOutcome(
                source: .local("/x/a.txt"),
                landedAt: .local("/dest/a.txt"),
                replacedExisting: true
            )
        ]
        #expect(UndoRecord.transfer(kind: .move, outcomes: allOverwrite) == nil)
    }

    // MARK: - Refuse to clobber

    @Test("undo refuses to overwrite a reoccupied original and reports it")
    func undoRefusesToClobber() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "one")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .move,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let record = try #require(
            UndoRecord.transfer(kind: .move, outcomes: CopyEngine.run(op, using: backend).outcomes)
        )
        // The user recreates something at the original path before undoing.
        try tree.writeFile("a.txt", contents: "two")

        let report = UndoJournal.revert(record, using: backend)
        #expect(!report.succeeded)
        #expect(report.failures.first?.error == .alreadyExists(tree.vfsPath("a.txt")))
        #expect(try contents(tree, "a.txt") == "two") // untouched
        #expect(try contents(tree, "dest/a.txt") == "one") // the moved copy left where it was
    }

    // MARK: - Stack semantics

    @Test("the stack is newest-on-top and bounded by capacity")
    func stackCapacity() {
        var journal = UndoJournal(capacity: 2)
        #expect(!journal.canUndo)
        journal.record(.newFolder(at: .local("/a")))
        journal.record(.newFolder(at: .local("/b")))
        journal.record(.newFolder(at: .local("/c"))) // evicts /a

        #expect(journal.records.count == 2)
        #expect(journal.top?.steps == [.removeCreatedFolder(.local("/c"))])
        #expect(journal.removeTop()?.steps == [.removeCreatedFolder(.local("/c"))])
        #expect(journal.top?.steps == [.removeCreatedFolder(.local("/b"))])
    }

    // MARK: - Persistence

    @Test("records round-trip through JSON so the journal survives relaunch")
    func codableRoundTrip() throws {
        let records = [
            UndoRecord.rename(from: .local("/dir/old name.txt"), to: .local("/dir/new name.txt")),
            UndoRecord(label: "Copy", steps: [
                .removeCopy(source: .local("/src/x"), copy: .local("/dest/x")),
                .restore(from: .local("/dest/y"), to: .local("/src/y"))
            ], nonReversibleCount: 2)
        ]
        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([UndoRecord].self, from: data)
        #expect(decoded == records)
    }
}

// MARK: - Test backend

/// Wraps `LocalBackend` but reports every rename as a cross-device error, exercising both
/// the move engine's copy-then-delete path and undo's cross-volume restore fallback.
private struct CrossVolumeBackend: VFSBackend {
    private let inner = LocalBackend()
    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        throw VFSError.io(path: source, code: EXDEV) // pretend every move crosses a volume
    }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool { false }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }
}
