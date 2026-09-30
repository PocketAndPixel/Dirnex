import Foundation
import Testing

@testable import DirnexCore

/// A rename the backend cannot perform in place, run as a queued job (PLAN.md §M21).
///
/// The case that produces it is an S3 "folder": a prefix is N objects, so `moveItem` answers
/// `EXDEV` rather than blocking on N server-side copies with no way to stop it or say how far it
/// got. `EXDEV` is already the signal `CopyEngine` turns into a recursive copy-then-delete, so the
/// only thing that was missing is a job that lands its one source under a *different* name —
/// ``FileOperation/renamedTo``.
///
/// The backend here is the same `EXDEV`-on-every-rename fake `CopyEngineTests` and
/// `UndoJournalTests` use, rather than a mounted second volume: what is under test is the engine's
/// fallback and the name it lands on, and both are decided by that one error.
@Suite("Queued rename")
struct QueuedRenameTests {
    private let backend = CrossVolumeRenameBackend()
    private let local = LocalBackend()

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try local.stat(at: tree.vfsPath(relative))
    }

    // MARK: - The engine lands the source under the new name

    @Test("a folder rename copies the whole subtree to the new name and removes the original")
    func renamesFolder() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("docs/sub")
        try tree.writeFile("docs/a.txt", contents: "a")
        try tree.writeFile("docs/sub/b.txt", contents: "b")

        let report = CopyEngine.run(
            FileOperation(renaming: try stat(tree, "docs"), to: "archive", in: tree.vfsPath()),
            using: backend
        )

        #expect(report.succeeded)
        #expect(FileManager.default.fileExists(atPath: tree.path("archive/sub/b.txt")))
        #expect(try String(contentsOfFile: tree.path("archive/a.txt"), encoding: .utf8) == "a")
        #expect(!FileManager.default.fileExists(atPath: tree.path("docs")))
    }

    /// The undo record is built from `outcomes`, so a rename that landed somewhere the outcome
    /// does not name is a rename ⌘Z cannot reverse.
    @Test("the outcome names the new path, so the job is undoable")
    func outcomeNamesTheNewPath() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("docs")
        try tree.writeFile("docs/a.txt", contents: "a")

        let report = CopyEngine.run(
            FileOperation(renaming: try stat(tree, "docs"), to: "archive", in: tree.vfsPath()),
            using: backend
        )

        #expect(report.outcomes.count == 1)
        #expect(report.outcomes.first?.source == tree.vfsPath("docs"))
        #expect(report.outcomes.first?.landedAt == tree.vfsPath("archive"))
    }

    /// A rename onto a name that is taken must not clobber the bystander — the same rule the
    /// inline path enforces with its own `stat`, held here by the conflict policy for the case
    /// where something appears between the check and the job running.
    @Test("renaming onto an existing name fails rather than overwriting it")
    func refusesAnOccupiedName() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("docs")
        try tree.writeFile("docs/a.txt", contents: "a")
        try tree.makeDir("archive")
        try tree.writeFile("archive/keep.txt", contents: "keep")

        let report = CopyEngine.run(
            FileOperation(renaming: try stat(tree, "docs"), to: "archive", in: tree.vfsPath()),
            using: backend,
            conflictPolicy: .fail
        )

        #expect(!report.succeeded)
        #expect(report.failures.count == 1)
        // The error names the *new* name, or the assertion passes for the wrong reason: a job that
        // ignored `renamedTo` collides with the source's own directory and refuses `docs` instead.
        // (The failure's `path` is the source either way, so it cannot tell the two apart.)
        #expect(report.failures.first?.error == .alreadyExists(tree.vfsPath("archive")))
        #expect(try String(contentsOfFile: tree.path("archive/keep.txt"), encoding: .utf8) == "keep")
        #expect(FileManager.default.fileExists(atPath: tree.path("docs/a.txt"))) // source untouched
    }

    /// The other side of the same property: nothing that is not a rename may pick up a new name.
    @Test("an ordinary move still lands every source under its own name")
    func ordinaryMoveKeepsNames() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "a")
        try tree.writeFile("b.txt", contents: "b")
        try tree.makeDir("dest")

        let operation = FileOperation(
            kind: .move,
            sources: [try stat(tree, "a.txt"), try stat(tree, "b.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(operation.renamedTo == nil)
        #expect(CopyEngine.run(operation, using: backend).succeeded)
        #expect(FileManager.default.fileExists(atPath: tree.path("dest/a.txt")))
        #expect(FileManager.default.fileExists(atPath: tree.path("dest/b.txt")))
    }

    @Test("landingName answers the source's own name unless the job is a rename")
    func landingName() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "a")
        let entry = try stat(tree, "a.txt")

        let move = FileOperation(kind: .move, sources: [entry], destinationDirectory: tree.vfsPath())
        let rename = FileOperation(renaming: entry, to: "b.txt", in: tree.vfsPath())
        #expect(move.landingName(for: entry) == "a.txt")
        #expect(rename.landingName(for: entry) == "b.txt")
    }

    // MARK: - Undo

    /// `crossVolumeRestore` used to require both ends to share a name, on the ground that "a rename
    /// never crosses volumes". A queued rename is exactly that case, so without the widening ⌘Z
    /// reports `EXDEV` on the one operation it was reached for.
    @Test("undo puts a queued rename back under its old name")
    func undoRestoresTheOldName() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("docs")
        try tree.writeFile("docs/a.txt", contents: "a")

        let report = CopyEngine.run(
            FileOperation(renaming: try stat(tree, "docs"), to: "archive", in: tree.vfsPath()),
            using: backend
        )
        let record = try #require(UndoRecord.transfer(kind: .move, outcomes: report.outcomes))
        let undone = UndoJournal.revert(record, using: backend)

        #expect(undone.failures.isEmpty)
        #expect(try String(contentsOfFile: tree.path("docs/a.txt"), encoding: .utf8) == "a")
        #expect(!FileManager.default.fileExists(atPath: tree.path("archive")))
    }

    /// Undo must never destroy what the user has put back at the old name in the meantime — the
    /// widening above removes a name check, so this pins that it removed the *right* one.
    @Test("undo refuses when the old name has been reoccupied")
    func undoRefusesAReoccupiedName() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("docs")
        try tree.writeFile("docs/a.txt", contents: "a")

        let report = CopyEngine.run(
            FileOperation(renaming: try stat(tree, "docs"), to: "archive", in: tree.vfsPath()),
            using: backend
        )
        try tree.writeFile("docs", contents: "something else entirely")

        let record = try #require(UndoRecord.transfer(kind: .move, outcomes: report.outcomes))
        let undone = UndoJournal.revert(record, using: backend)

        #expect(!undone.failures.isEmpty)
        #expect(
            try String(contentsOfFile: tree.path("docs"), encoding: .utf8) == "something else entirely"
        )
    }
}

// MARK: - Test backend

/// `LocalBackend` with every rename refused as `EXDEV` — an S3 prefix's answer, and the one input
/// that decides both the engine's fallback and undo's.
private struct CrossVolumeRenameBackend: VFSBackend {
    private let inner = LocalBackend()
    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        throw VFSError.io(path: source, code: EXDEV)
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
