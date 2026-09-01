import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Undoing a rewrite of a **real** archive, end to end (HISTORY.md ▸ After M19, 2026-09-01): the
/// app's own writer produces the container, captures the one it displaced, and the core's journal
/// swaps them back.
///
/// The core suites pin the budget's arithmetic and the swap's mechanics against files of no
/// particular kind. What only this target can ask is whether the thing that comes back is an
/// *archive* — that `bsdtar` and libarchive both hand the copy over at the right moment, and that
/// what ⌘Z restores still opens.
@Suite("Archive rewrite undo")
struct ArchiveUndoReachTests {
    private let backend = LocalBackend()

    // MARK: - The round trip

    @Test("undoing a delete brings the member back, byte for byte")
    func undoDelete() throws {
        let fixture = try Fixture()
        let before = try fixture.archiveBytes()

        let snapshot = try #require(try ArchiveWriter.delete(
            innerPaths: ["/one.txt"], fromArchiveAt: fixture.archive, undo: fixture.undo
        ))
        #expect(try fixture.members() == ["./", "./two.txt"])

        // Driven through a real journal rather than by inverting the record by hand, so the stack
        // shuffling `UndoController` relies on is exercised too.
        var journal = UndoJournal()
        journal.record(try #require(snapshot.record()))

        let undone = try #require(journal.takeForUndo()?.fileOperation)
        #expect(UndoJournal.revert(undone, using: backend).succeeded)
        // Byte-identical, which a re-pack could never be: what is put back is the container the
        // user had, not one rebuilt from its contents.
        #expect(try fixture.archiveBytes() == before)
        // Down to the member *spelling*, which is the sharpest witness available here: the fixture
        // is packed by libarchive under bare names and `bsdtar` rewrites it under `./` ones (the
        // pre-existing difference `ArchiveWriterEncryptedTests` pins), so an undo that rebuilt the
        // archive rather than restoring it would come back with the rewrite's spelling.
        #expect(try fixture.members() == ["one.txt", "two.txt"])

        // And redo puts the rewrite back off the same one snapshot — nothing else was stored.
        let redone = try #require(journal.takeForRedo()?.fileOperation)
        #expect(UndoJournal.revert(redone, using: backend).succeeded)
        #expect(try fixture.members() == ["./", "./two.txt"])
        #expect(fixture.storeContents().count == 1)
    }

    @Test("undoing an add removes what was added")
    func undoAdd() throws {
        let fixture = try Fixture()
        let extra = fixture.directory.appendingPathComponent("added.txt")
        try "added".write(to: extra, atomically: true, encoding: .utf8)

        let snapshot = try #require(try ArchiveWriter.add(
            localPaths: [extra.path],
            toInnerDirectory: "/",
            ofArchiveAt: fixture.archive,
            undo: fixture.undo
        ))
        #expect(try fixture.members().contains("./added.txt"))

        #expect(UndoJournal.revert(try #require(snapshot.record()), using: backend).succeeded)
        #expect(try !fixture.members().contains("./added.txt"))
    }

    @Test("an encrypted archive is undone through the same one step, and still opens")
    func undoEncryptedDelete() throws {
        let fixture = try Fixture(encryption: .aes256)
        let snapshot = try #require(try ArchiveWriter.delete(
            innerPaths: ["/one.txt"],
            fromArchiveAt: fixture.archive,
            passphrase: Fixture.passphrase,
            undo: fixture.undo
        ))
        #expect(UndoJournal.revert(try #require(snapshot.record()), using: backend).succeeded)

        // The claim is not that the bytes came back — the core proves that for any file — but that
        // what came back is still an encrypted archive that opens with the same passphrase.
        let inspection = try EncryptedArchiveReader.inspect(archiveAt: fixture.archive)
        #expect(inspection.needsPassphrase)
        #expect(inspection.entries.map(\.archivePath).sorted() == ["one.txt", "two.txt"])
        #expect(try fixture.readBack("one.txt") == "first")
    }

    // MARK: - When there is nothing to put back

    @Test("a rewrite that fails leaves no snapshot behind")
    func failedRewriteStoresNothing() throws {
        let fixture = try Fixture(encryption: .aes256)
        #expect(throws: (any Error).self) {
            try ArchiveWriter.delete(
                innerPaths: ["/one.txt"],
                fromArchiveAt: fixture.archive,
                passphrase: ArchivePassphrase("not-it"),
                undo: fixture.undo
            )
        }
        // A snapshot of an archive that was never replaced is a copy of a file the user still has,
        // holding budget away from a rewrite that did happen.
        #expect(fixture.storeContents().isEmpty)
    }

    @Test("a caller that wants no undo gets none, and the store stays empty")
    func undoCanBeDeclined() throws {
        let fixture = try Fixture()
        let snapshot = try ArchiveWriter.delete(
            innerPaths: ["/one.txt"], fromArchiveAt: fixture.archive, undo: .none
        )
        #expect(snapshot == nil)
        #expect(try fixture.members() == ["./", "./two.txt"])
        #expect(fixture.storeContents().isEmpty)
    }

    @Test("an archive over the whole budget is rewritten and not journalled")
    func overTheBudgetIsNotUndoable() throws {
        let fixture = try Fixture()
        let tiny = ArchiveUndoStorage.Request(
            store: ArchiveUndoStore(
                root: fixture.directory.appendingPathComponent("tiny-store"),
                budget: ArchiveUndoBudget(bytes: 1)
            ),
            live: []
        )
        let snapshot = try ArchiveWriter.delete(
            innerPaths: ["/one.txt"], fromArchiveAt: fixture.archive, undo: tiny
        )
        // The rewrite still happens — the budget decides whether it can be *reversed*, never
        // whether it may run. The gesture's own sheet said which it would be before it started.
        #expect(snapshot == nil)
        #expect(try fixture.members() == ["./", "./two.txt"])
    }

    // MARK: - What the store is pruned against

    @Test("the persisted journal names its snapshots, furthest from the next ⌘Z first")
    func liveSetIsOrdered() throws {
        let key = "Dirnex.undoJournal"
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(
                forKey: key
            ) }
        }

        let witness = ArchiveUndoWitness(byteSize: 1, modified: Date(timeIntervalSince1970: 1))
        func record(_ snapshot: String) -> UndoRecord {
            .archiveRewrite(
                archive: .local("/tmp/a.zip"),
                snapshot: .local(snapshot),
                expected: witness,
                restored: witness
            )
        }
        // Written the way `UndoController` writes it: oldest at the bottom of each stack.
        let blob = try JSONEncoder().encode([
            "undo": [record("/s/old"), record("/s/new")],
            "redo": [record("/s/redone")]
        ])
        defaults.set(blob, forKey: key)

        // The undo stack's bottom is the furthest thing from any key the user can press, so it is
        // the first to be given up; a redo entry is one ⇧⌘Z away and goes last.
        #expect(UndoController.persistedArchiveSnapshots() == ["/s/old", "/s/new", "/s/redone"])
    }

    @Test("a journal that names no archive prunes the store empty")
    func unreferencedSnapshotsGo() throws {
        let fixture = try Fixture()
        let store = try #require(fixture.undo.store)
        _ = try ArchiveWriter.delete(
            innerPaths: ["/one.txt"], fromArchiveAt: fixture.archive, undo: fixture.undo
        )
        #expect(fixture.storeContents().count == 1)

        store.prune(live: [])
        #expect(fixture.storeContents().isEmpty)
    }

    /// A real archive on disk plus a store of its own, so nothing here can reach the app's — which
    /// in this target is the developer's own Application Support (see `ArchiveUndoStorage.Request`).
    private struct Fixture {
        static let passphrase = ArchivePassphrase("correct horse")

        let directory: URL
        let archive: String
        let undo: ArchiveUndoStorage.Request
        private let encryption: ArchiveEncryption

        init(encryption: ArchiveEncryption = .none) throws {
            self.encryption = encryption
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveUndoReach-\(UUID().uuidString)")
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "first".write(
                to: source.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8
            )
            try "second".write(
                to: source.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8
            )
            undo = ArchiveUndoStorage.Request(
                store: ArchiveUndoStore(root: directory.appendingPathComponent("undo-store")),
                live: []
            )
            archive = directory.appendingPathComponent("fixture.zip").path
            try EncryptedArchiveWriter.write(
                items: try ArchiveSourceEnumerator.items(
                    inDirectory: source.path, names: ["one.txt", "two.txt"]
                ),
                toArchiveAt: archive,
                encryption: encryption,
                passphrase: encryption.isEncrypted ? Self.passphrase : nil,
                namePrivacy: .visible
            )
        }

        func archiveBytes() throws -> Data {
            try Data(contentsOf: URL(fileURLWithPath: archive))
        }

        func members() throws -> [String] {
            try EncryptedArchiveReader.inspect(archiveAt: archive).entries
                .map(\.archivePath).sorted()
        }

        func storeContents() -> [String] {
            (undo.store?.held() ?? []).map(\.path)
        }

        func readBack(_ name: String) throws -> String {
            let out = directory.appendingPathComponent("read-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: out) }
            _ = try EncryptedArchiveReader.extract(
                archiveAt: archive,
                into: out.path,
                passphrase: encryption.isEncrypted ? Self.passphrase : nil
            )
            return try String(
                contentsOf: out.appendingPathComponent(name), encoding: .utf8
            )
        }
    }
}
