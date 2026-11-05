import Foundation
import Testing

@testable import DirnexCore

/// A search snapshot after the app deleted or moved a folder some of its hits are in (2026-11-05).
///
/// Until then a delete or a move took out only the row whose path was the item's own, so a hit
/// inside a moved folder stayed, naming the folder's old place.
@Suite("Search snapshot: a folder that left")
struct SearchSnapshotFolderTests {
    private static func hit(_ path: String, kind: FileEntry.Kind = .file) -> FileEntry {
        let vfsPath = VFSPath.local(path)
        return FileEntry(
            path: vfsPath,
            name: vfsPath.lastComponent,
            kind: kind,
            byteSize: 128,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 900_000),
            isHidden: false,
            permissions: 0o644,
            inode: 7
        )
    }

    /// The reported search: `notes` in `~/Work`, with a sibling whose name starts with the folder's
    /// and a folder whose name does too, both of which are outside it.
    private static let found = [
        hit("/w/notes", kind: .directory),
        hit("/w/notes/a.txt"),
        hit("/w/notes/deep/b.txt"),
        hit("/w/other/notes-c.txt"),
        hit("/w/notes-d.txt"),
        hit("/w/notes2/e.txt")
    ]

    private static let outside = ["notes-c.txt", "notes-d.txt", "e.txt"]

    // MARK: - Applying

    /// The reported case: F6 on the folder hit. Everything inside it, at any depth, leaves with it,
    /// and nothing that merely shares the start of its name does.
    @Test("a moved folder hit takes the hits inside it along")
    func movedFolderTakesItsHits() throws {
        let applied = try #require(SearchSnapshot.applying(
            [.moved(.local("/w/notes"), to: .local("/archive/notes"))],
            to: Self.found
        ))
        #expect(applied.entries.map(\.name) == Self.outside)
        #expect(applied.departed.map(\.name) == ["notes", "a.txt", "b.txt"])
    }

    /// F8 and ⇧F8 on the folder hit: the files inside are gone with it.
    @Test("a deleted folder hit takes the hits inside it along")
    func deletedFolderTakesItsHits() throws {
        let applied = try #require(
            SearchSnapshot.applying([.removed(.local("/w/notes"))], to: Self.found)
        )
        #expect(applied.entries.map(\.name) == Self.outside)
        #expect(applied.departed.map(\.name) == ["notes", "a.txt", "b.txt"])
    }

    /// Moved or deleted from a folder tab: the folder was never a hit, and the hits inside it still
    /// name a place that is no longer there.
    @Test("a folder that was not a hit still takes the hits inside it along")
    func folderThatWasNotAHit() throws {
        let entries = Array(Self.found.dropFirst())
        let moved = try #require(SearchSnapshot.applying(
            [.moved(.local("/w/notes"), to: .local("/archive/notes"))],
            to: entries
        ))
        #expect(moved.entries.map(\.name) == Self.outside)
        #expect(moved.departed.map(\.name) == ["a.txt", "b.txt"])

        let deleted = try #require(
            SearchSnapshot.applying([.removed(.local("/w/notes"))], to: entries)
        )
        #expect(deleted.entries.map(\.name) == Self.outside)
        #expect(deleted.departed.map(\.name) == ["a.txt", "b.txt"])
    }

    /// The narrowness controls. A folder no hit is inside changes nothing; and the same path on
    /// another backend is somewhere else, however it is spelled.
    @Test("a folder no hit is inside, and the same path elsewhere, change nothing")
    func otherFoldersChangeNothing() {
        #expect(SearchSnapshot.applying([.removed(.local("/w/empty"))], to: Self.found) == nil)
        #expect(SearchSnapshot.applying([.removed(.local("/w/notes/a.txt"))], to: [
            Self.hit("/w/notes/a.txt.bak")
        ]) == nil)
        let server = VFSPath(
            backend: .sftp(SFTPLocation(host: "box", username: "tester")),
            path: "/w/notes"
        )
        #expect(SearchSnapshot.applying([.removed(server)], to: Self.found) == nil)
    }

    /// A move that stayed in the folder's own folder is a queued rename, and the hits inside it
    /// follow it rather than leave (``SearchSnapshot/renaming(_:after:)``).
    @Test("a folder renamed by a job still carries its hits")
    func renamedFolderStillCarries() throws {
        let applied = try #require(SearchSnapshot.applying(
            [.moved(.local("/w/notes"), to: .local("/w/notes_v2"))],
            to: Self.found
        ))
        #expect(applied.departed.isEmpty)
        #expect(applied.entries.map(\.path) == [
            .local("/w/notes_v2"),
            .local("/w/notes_v2/a.txt"),
            .local("/w/notes_v2/deep/b.txt"),
            .local("/w/other/notes-c.txt"),
            .local("/w/notes-d.txt"),
            .local("/w/notes2/e.txt")
        ])
    }

    /// A folder and a file inside it, both marked and moved: either way round the engine takes
    /// them, both rows go, once each.
    @Test("a folder moved with a hit inside it marked too leaves each row once")
    func folderAndItsContentMovedTogether() throws {
        let applied = try #require(SearchSnapshot.applying(
            [
                .moved(.local("/w/notes"), to: .local("/archive/notes")),
                .moved(.local("/w/notes/a.txt"), to: .local("/archive/a.txt"))
            ],
            to: Self.found
        ))
        #expect(applied.entries.map(\.name) == Self.outside)
        #expect(applied.departed.map(\.name) == ["notes", "a.txt", "b.txt"])
    }

    // MARK: - Against the disk

    /// The whole chain on a real tree: the engine moves the folder, the report says what moved, the
    /// snapshot loses the folder and what is inside it, the journal's own undo moves it back, and
    /// every row returns because every file is where the search found it.
    @Test("against the engine and the journal, the hits inside come back with ⌘Z")
    func engineRoundTrip() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        for folder in ["Work/notes", "Work/other", "Archive"] {
            try tree.makeDir(folder)
        }
        try tree.writeFile("Work/notes/a.txt", contents: "a")
        try tree.writeFile("Work/other/notes-c.txt", contents: "c")
        let backend = LocalBackend()
        let hits = try ["Work/notes", "Work/notes/a.txt", "Work/other/notes-c.txt"].map {
            try backend.stat(at: tree.vfsPath($0))
        }

        let report = CopyEngine.run(
            FileOperation(
                kind: .move,
                sources: [hits[0]],
                destinationDirectory: tree.vfsPath("Archive")
            ),
            using: backend,
            conflictPolicy: .skip
        )
        let applied = try #require(SearchSnapshot.applying(
            SearchSnapshot.changes(made: report, by: .move),
            to: hits
        ))
        #expect(applied.entries.map(\.name) == ["notes-c.txt"])
        #expect(applied.departed.map(\.name) == ["notes", "a.txt"])
        #expect(FileManager.default.fileExists(atPath: tree.path("Archive/notes/a.txt")))

        let record = try #require(UndoRecord.transfer(kind: .move, outcomes: report.outcomes))
        let undo = UndoJournal.revert(record, using: backend)
        try #require(undo.failures.isEmpty)
        let present = SearchSnapshot.present(applied.departed.map(\.path), using: backend)
        let shown = try #require(SearchSnapshot.reconciled(
            applied.entries,
            departed: applied.departed,
            present: present
        ))
        #expect(Set(shown.map(\.path)) == Set(hits.map(\.path)))
    }
}
