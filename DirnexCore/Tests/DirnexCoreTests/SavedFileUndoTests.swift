import Foundation
import Testing

@testable import DirnexCore

/// A save from the compare window on the undo stack (PLAN.md §M33 Slice 3): `save + undo + redo ==
/// save`, written in place both ways, and the archive step's two refusals.
@Suite("SavedFileUndo")
struct SavedFileUndoTests {
    private typealias Fixture = SavedFileFixture

    private let backend = LocalBackend()
    private static let text = "one\ntwo\nthree\n"
    private static let savedText = "one\ntwo\nx\n"

    /// Save an edit of the file at `path` with a store under `tree`, and hand back the record.
    private static func saved(_ path: String, in tree: TempTree) throws -> UndoRecord {
        try tree.makeDir("store")
        let store = ArchiveUndoStore(root: URL(fileURLWithPath: tree.path("store")))
        let saved = try ComparedFileSave.save(
            try Fixture.edited(text, lastLine: "x"),
            to: .reading(path),
            undo: .init(store: store, live: [])
        )
        return try #require(saved.undo)
    }

    private static func snapshot(of record: UndoRecord) throws -> String {
        try #require(record.archiveSnapshotPaths.first)
    }

    // MARK: - The round trip

    @Test("undo puts the old bytes and time back in the same file, and redo the saved ones")
    func undoThenRedo() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        try FileManager.default.linkItem(atPath: path, toPath: tree.path("b.txt"))
        try Fixture.dress(path)
        try tree.setModificationDate("a.txt", to: Date(timeIntervalSince1970: 1_700_000_000.5))
        let before = try Fixture.look(path)
        let readTime = try #require(Fixture.modificationTime(path))

        let record = try Self.saved(path, in: tree)
        #expect(record.label == .saveFile)

        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(Fixture.read(path) == Self.text)
        #expect(Fixture.read(tree.path("b.txt")) == Self.text)
        #expect(try Fixture.look(path) == before)
        let undone = try #require(Fixture.modificationTime(path))
        #expect(undone.tv_sec == readTime.tv_sec && undone.tv_nsec == readTime.tv_nsec)

        #expect(UndoJournal.revert(record.inverted, using: backend).succeeded)
        #expect(Fixture.read(path) == Self.savedText)
        #expect(try Fixture.look(path) == before)

        // A second lap, since the step being its own inverse is the whole design.
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(Fixture.read(tree.path("b.txt")) == Self.text)
    }

    @Test("a save through a symlink is undone in its target, and the link stays a link")
    func undoesThroughASymlink() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let target = try tree.writeFile("target.txt", contents: Self.text)
        try tree.symlink("link.txt", to: "target.txt")

        let record = try Self.saved(tree.path("link.txt"), in: tree)
        guard case let .restoreSavedFile(file, _, _, _) = record.steps.first else {
            Issue.record("not a saved-file step")
            return
        }
        #expect(file.path == ComparedFileSave.resolvedPath(target))

        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(Fixture.read(target) == Self.text)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: tree.path("link.txt"))
                == "target.txt"
        )
    }

    @Test("a file whose ACL denies delete is undone too, as a rename could not")
    func undoesThroughAnACLThatDeniesDelete() throws {
        let tree = try TempTree()
        defer {
            Fixture.clearAccessControl(under: tree.root.path)
            tree.cleanup()
        }
        let path = try tree.writeFile("denied.txt", contents: Self.text)
        try Fixture.dress(path, acl: "everyone deny delete")

        let record = try Self.saved(path, in: tree)
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(Fixture.read(path) == Self.text)
    }

    @Test("the step is its own inverse, survives the journal's JSON, and keeps its snapshot live")
    func stepInvertsAndPersists() throws {
        let step = UndoStep.restoreSavedFile(
            file: .local("/tmp/a.txt"),
            snapshot: .local("/tmp/store/s"),
            expected: .init(byteSize: 10, modified: Date(timeIntervalSince1970: 1.5)),
            restored: .init(byteSize: 20, modified: Date(timeIntervalSince1970: 2.5))
        )
        #expect(step.inverse.inverse == step)
        #expect(step.inverse != step)
        let decoded = try JSONDecoder().decode(UndoStep.self, from: JSONEncoder().encode(step))
        #expect(decoded == step)

        // The store prunes every snapshot no record names, so a step left out of this would have
        // its copy deleted at the next launch.
        let record = UndoRecord(label: .saveFile, steps: [step])
        #expect(record.archiveSnapshotPaths == ["/tmp/store/s"])
    }

    // MARK: - The refusals

    @Test("an undo whose copy has been evicted is refused by name")
    func refusesWhenTheSnapshotIsGone() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let record = try Self.saved(path, in: tree)
        try FileManager.default.removeItem(atPath: Self.snapshot(of: record))

        let report = UndoJournal.revert(record, using: backend)
        #expect(
            report.failures.first?.error
                == .unsupported(.archiveUndoCopyUnavailable(archive: "a.txt"))
        )
        #expect(Fixture.read(path) == Self.savedText)
    }

    @Test("a file changed since the save is refused rather than written over")
    func refusesWhenTheFileMovedOn() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let record = try Self.saved(path, in: tree)
        try tree.writeFile("a.txt", contents: "somebody else's version\n")

        let report = UndoJournal.revert(record, using: backend)
        #expect(
            report.failures.first?.error
                == .unsupported(.archiveChangedSinceRewrite(archive: "a.txt"))
        )
        #expect(Fixture.read(path) == "somebody else's version\n")
    }

    @Test("an undo whose write fails partway leaves the saved bytes and the copy as they were")
    func keepsBothVersionsAfterAFailedUndo() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let record = try Self.saved(path, in: tree)
        let snapshot = try Self.snapshot(of: record)
        let fillsUp: InPlaceFileWrite.Writer = { descriptor, data in
            _ = InPlaceFileWrite.writeAll(descriptor, data.prefix(1))
            return ENOSPC
        }

        #expect(throws: VFSError.io(path: .local(path), code: ENOSPC)) {
            try ArchiveUndoStore.exchangeInPlace(fileAt: path, snapshotAt: snapshot, writer: fillsUp)
        }
        #expect(Fixture.read(path) == Self.savedText)
        #expect(Fixture.read(snapshot) == Self.text)
        #expect(!FileManager.default.fileExists(atPath: snapshot + ".incoming"))
        // And the record still undoes, since the file is still the one the save produced.
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(Fixture.read(path) == Self.text)
    }
}
