import Foundation
import Testing

@testable import DirnexCore

/// A search snapshot after the app renamed a hit, or a folder hits are in (2026-11-05).
@Suite("Search snapshot: renames")
struct SearchSnapshotRenameTests {
    private typealias Renamed = SearchSnapshot.Renamed

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

    private static func rename(_ from: String, _ to: String) -> Renamed {
        Renamed(from: .local(from), to: .local(to))
    }

    // MARK: - One path

    @Test("a renamed item, and everything inside a renamed folder, move with the rename")
    func pathFollowsTheRename() {
        let renames = [Self.rename("/d/docs", "/d/guides")]
        #expect(SearchSnapshot.path(.local("/d/docs"), after: renames) == .local("/d/guides"))
        #expect(
            SearchSnapshot.path(.local("/d/docs/a.txt"), after: renames) == .local("/d/guides/a.txt")
        )
        #expect(
            SearchSnapshot.path(.local("/d/docs/api/x.md"), after: renames) == .local(
                "/d/guides/api/x.md"
            )
        )
    }

    /// The narrowness controls: a sibling whose name merely starts with the folder's is not inside
    /// it, and a path on another backend is not this rename's business however it is spelled.
    @Test("a sibling sharing the folder's prefix, and another backend, are left alone")
    func pathLeavesOthersAlone() {
        let renames = [Self.rename("/d/docs", "/d/guides")]
        #expect(
            SearchSnapshot.path(.local("/d/docs2/a.txt"), after: renames) == .local("/d/docs2/a.txt")
        )
        #expect(SearchSnapshot.path(.local("/d/doc"), after: renames) == .local("/d/doc"))
        let archive = VFSPath(backend: .archive(forArchiveAt: "/x.zip"), path: "/d/docs/a.txt")
        #expect(SearchSnapshot.path(archive, after: renames) == archive)
    }

    /// ⇧F2's order: the file inside the folder first, while the folder still has its old name, then
    /// the folder. Folded in that order, the file lands under the folder's new name.
    @Test("a batch folds in the order it ran")
    func batchFoldsInOrder() {
        let renames = [
            Self.rename("/d/docs/a.txt", "/d/docs/b.txt"),
            Self.rename("/d/docs", "/d/guides")
        ]
        #expect(
            SearchSnapshot.path(.local("/d/docs/a.txt"), after: renames) == .local("/d/guides/b.txt")
        )
        #expect(
            SearchSnapshot.path(.local("/d/docs/c.txt"), after: renames) == .local("/d/guides/c.txt")
        )
    }

    // MARK: - The rows

    @Test("every row the renames reach moves, keeping its order and its own name")
    func renamingMovesTheRows() throws {
        let entries = [
            Self.hit("/d/docs", kind: .directory),
            Self.hit("/d/docs/a.txt"),
            Self.hit("/d/top.txt")
        ]
        let renamed = try #require(
            SearchSnapshot.renaming(entries, after: [Self.rename("/d/docs", "/d/guides")])
        )

        #expect(
            renamed.map(\.path) == [
                .local("/d/guides"),
                .local("/d/guides/a.txt"),
                .local("/d/top.txt")
            ]
        )
        #expect(renamed.map(\.name) == ["guides", "a.txt", "top.txt"])
        // A move of its folder changes nothing else about the file.
        #expect(renamed[1].byteSize == 128 && renamed[1].inode == 7)
    }

    @Test("renames that reach no row answer nil")
    func renamingNothingIsNil() {
        let entries = [Self.hit("/d/top.txt")]
        #expect(
            SearchSnapshot.renaming(entries, after: [Self.rename("/d/docs", "/d/guides")]) == nil
        )
        #expect(SearchSnapshot.renaming(entries, after: []) == nil)
    }

    /// A rename that ran as a queued job (an S3 prefix) arrives as a move within its own folder,
    /// and carries the hits inside the folder the same way.
    @Test("a queued rename of a folder carries the hits inside it")
    func queuedRenameCarriesItsContents() throws {
        let entries = [
            Self.hit("/d/docs", kind: .directory),
            Self.hit("/d/docs/a.txt"),
            Self.hit("/d/top.txt")
        ]
        let applied = try #require(
            SearchSnapshot.applying(
                [.moved(.local("/d/docs"), to: .local("/d/guides"))],
                to: entries
            )
        )
        #expect(
            applied.entries.map(\.path) == [
                .local("/d/guides"),
                .local("/d/guides/a.txt"),
                .local("/d/top.txt")
            ]
        )
        #expect(applied.departed.isEmpty)
    }

    /// The control on the other side: a folder moved somewhere else has left, and the move rules
    /// that were there before are unchanged for it.
    @Test("a folder moved to another folder still leaves")
    func movedElsewhereStillLeaves() throws {
        let entries = [Self.hit("/d/docs", kind: .directory), Self.hit("/d/top.txt")]
        let applied = try #require(
            SearchSnapshot.applying([.moved(.local("/d/docs"), to: .local("/e/docs"))], to: entries)
        )
        #expect(applied.entries.map(\.path) == [.local("/d/top.txt")])
        #expect(applied.departed.map(\.path) == [.local("/d/docs")])
    }

    // MARK: - Undo and redo

    /// The renames an undo carried out are its own `.restore` steps, in the order it ran them, and
    /// folding them puts every row back. Redo, the inverted record, folds them forward again.
    @Test("undo and redo of a batch put the rows where the disk has them")
    func undoAndRedoRoundTrip() throws {
        let original = [
            Self.hit("/d/docs", kind: .directory),
            Self.hit("/d/docs/a.txt"),
            Self.hit("/d/top.txt")
        ]
        // The batch as ⇧F2 runs it, deepest first.
        let applied = [
            Self.rename("/d/docs/a.txt", "/d/docs/b.txt"),
            Self.rename("/d/docs", "/d/guides")
        ]
        let renamed = try #require(SearchSnapshot.renaming(original, after: applied))
        // Spelled out, so the round trip below cannot pass by undoing a wrong answer exactly.
        #expect(
            renamed.map(\.path) == [
                .local("/d/guides"),
                .local("/d/guides/b.txt"),
                .local("/d/top.txt")
            ]
        )
        let record = try #require(
            UndoRecord.multiRename(applied.map { (original: $0.from, renamed: $0.to) })
        )

        let undone = SearchSnapshot.renames(appliedBy: record, report: UndoReport(failures: []))
        #expect(
            try #require(SearchSnapshot.renaming(renamed, after: undone)).map(\.path) == original.map(
                \.path
            )
        )

        let redone = SearchSnapshot.renames(
            appliedBy: record.inverted,
            report: UndoReport(failures: [])
        )
        #expect(
            try #require(SearchSnapshot.renaming(original, after: redone)).map(\.path) == renamed.map(
                \.path
            )
        )
    }

    /// A step the report names did not happen, so its row must not move as though it had.
    @Test("a failed step is not a rename")
    func failedStepsAreLeftOut() {
        let record = UndoRecord.rename(from: .local("/d/old.txt"), to: .local("/d/new.txt"))
        let failure = OperationItemFailure(
            path: .local("/d/old.txt"),
            error: .alreadyExists(.local("/d/old.txt"))
        )
        #expect(
            SearchSnapshot.renames(appliedBy: record, report: UndoReport(failures: [failure])).isEmpty
        )
        #expect(
            SearchSnapshot.renames(appliedBy: record, report: UndoReport(failures: []))
                == [Self.rename("/d/new.txt", "/d/old.txt")]
        )
    }

    /// An undone move crosses folders, so it is not a rename; its hit is followed by the departed-hit
    /// reconciliation instead.
    @Test("an undone move is not a rename")
    func movesAreNotRenames() {
        let record = UndoRecord(
            label: .move,
            steps: [.restore(from: .local("/e/a.txt"), to: .local("/d/a.txt"))]
        )
        #expect(SearchSnapshot.renames(appliedBy: record, report: UndoReport(failures: [])).isEmpty)
    }
}
