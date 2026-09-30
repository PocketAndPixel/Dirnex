import Foundation
import Testing

@testable import DirnexCore

/// An archive rewrite on the undo stack: `rewrite + undo + redo == rewrite`, and the two refusals
/// that keep a ⌘Z days later from discarding something (HISTORY.md ▸ After M19, 2026-09-01).
@Suite("ArchiveUndoJournal")
struct ArchiveUndoJournalTests {
    private let backend = LocalBackend()

    private func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<none>"
    }

    /// The shape every test here starts from: an archive captured, then rewritten, then journalled.
    private func rewritten(_ tree: TempTree) throws -> (record: UndoRecord, snapshot: String) {
        try tree.makeDir("store")
        try tree.writeFile("a.zip", contents: "original")
        let store = ArchiveUndoStore(root: URL(fileURLWithPath: tree.path("store")))
        let taken = try #require(store.capture(archiveAt: tree.path("a.zip"), live: []))
        try tree.writeFile("a.zip", contents: "rewritten")
        return (try #require(taken.record()), taken.snapshot)
    }

    // MARK: - The round trip

    @Test("undo puts the archive back, and redo puts the rewrite back")
    func undoThenRedo() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (record, _) = try rewritten(tree)
        #expect(record.label == .changeArchive)

        let undo = UndoJournal.revert(record, using: backend)
        #expect(undo.succeeded)
        #expect(read(tree.path("a.zip")) == "original")

        let redo = UndoJournal.revert(record.inverted, using: backend)
        #expect(redo.succeeded)
        #expect(read(tree.path("a.zip")) == "rewritten")

        // And again, because the whole design rests on the step being its own inverse rather than
        // on a second stored copy: a second lap must not degrade.
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(read(tree.path("a.zip")) == "original")
    }

    @Test("the step is its own inverse, and survives the journal's JSON")
    func stepInvertsAndPersists() throws {
        let step = UndoStep.restoreArchive(
            archive: .local("/tmp/a.zip"),
            snapshot: .local("/tmp/store/s"),
            expected: .init(byteSize: 10, modified: Date(timeIntervalSince1970: 1.5)),
            restored: .init(byteSize: 20, modified: Date(timeIntervalSince1970: 2.5))
        )
        #expect(step.inverse.inverse == step)
        #expect(step.inverse != step)

        // The journal is JSON in `UserDefaults`, and the witness compares a modification time
        // *exactly* — so a lossy round trip would refuse every undo taken before a relaunch.
        let encoded = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(UndoStep.self, from: encoded)
        #expect(decoded == step)
    }

    @Test("a rewritten archive keeps a modification time an undo can be checked against")
    func witnessSurvivesNanoseconds() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.zip", contents: "x")
        let witness = try #require(ArchiveUndoWitness.current(ofFileAt: tree.path("a.zip")))
        let encoded = try JSONEncoder().encode(witness)
        let decoded = try JSONDecoder().decode(ArchiveUndoWitness.self, from: encoded)
        #expect(decoded == witness)
        #expect(decoded.matchesFile(at: tree.path("a.zip")))
    }

    // MARK: - The refusals

    @Test("an undo whose snapshot has been evicted is refused by name, not silently skipped")
    func refusesWhenTheSnapshotIsGone() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (record, snapshot) = try rewritten(tree)
        try FileManager.default.removeItem(atPath: snapshot)

        let report = UndoJournal.revert(record, using: backend)
        #expect(report.failures.count == 1)
        #expect(
            report.failures.first?.error
                == .unsupported(.archiveUndoCopyUnavailable(archive: "a.zip"))
        )
        #expect(read(tree.path("a.zip")) == "rewritten")
    }

    @Test("an archive something else has changed since is refused rather than discarded")
    func refusesWhenTheArchiveMovedOn() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (record, _) = try rewritten(tree)
        // Somebody else's write — a sync client, another tool, a second rewrite this record cannot
        // know about. Undo protects it over completing the reversal.
        try tree.writeFile("a.zip", contents: "somebody else's version")

        let report = UndoJournal.revert(record, using: backend)
        #expect(
            report.failures.first?.error
                == .unsupported(.archiveChangedSinceRewrite(archive: "a.zip"))
        )
        #expect(read(tree.path("a.zip")) == "somebody else's version")
    }

    @Test("an archive deleted since is refused, not re-created")
    func refusesWhenTheArchiveIsGone() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (record, _) = try rewritten(tree)
        try FileManager.default.removeItem(atPath: tree.path("a.zip"))

        let report = UndoJournal.revert(record, using: backend)
        #expect(
            report.failures.first?.error
                == .unsupported(.archiveChangedSinceRewrite(archive: "a.zip"))
        )
        #expect(!FileManager.default.fileExists(atPath: tree.path("a.zip")))
    }

    // MARK: - What the store prunes against

    @Test("a record names the snapshot the store must keep")
    func recordNamesItsSnapshot() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (record, snapshot) = try rewritten(tree)
        #expect(record.archiveSnapshotPaths == [snapshot])
        // Inverting is what the redo stack holds, and it must protect the same bytes.
        #expect(record.inverted.archiveSnapshotPaths == [snapshot])
        // A record of any other kind names none, so a journal full of moves prunes the store empty.
        #expect(UndoRecord.newFolder(at: .local("/tmp/x")).archiveSnapshotPaths.isEmpty)
    }
}
