import Foundation
import Testing

@testable import DirnexCore

/// Stop partway through a copy or a move (PLAN.md §M41 Slice 3): what was written stays, the report
/// names it, and the undo record takes it away.
///
/// Found in the live run: Stop on one big folder left the files that had finished, with no undo
/// record at all, under a question that said "⌘Z undoes it". A move does the same, since it copies
/// the whole item before it removes the source.
@Suite("CopyEngine: stopped partway")
struct CopyEngineStopTests {
    private let local = LocalBackend()

    /// `top/` holding three files, an empty `dest/`, and `first.txt` beside them.
    private func makeTree() throws -> TempTree {
        let tree = try TempTree()
        try tree.makeDir("top")
        for name in ["a", "b", "c"] {
            try tree.writeFile("top/\(name).txt", contents: name)
        }
        try tree.writeFile("first.txt", contents: "first")
        try tree.makeDir("dest")
        return tree
    }

    private func run(
        _ kind: FileOperation.Kind,
        _ sources: [String],
        in tree: TempTree,
        on backend: StoppingBackend
    ) throws -> OperationReport {
        let operation = FileOperation(
            kind: kind,
            sources: try sources.map { try local.stat(at: tree.vfsPath($0)) },
            destinationDirectory: tree.vfsPath("dest")
        )
        return CopyEngine.run(operation, using: backend, isCancelled: { backend.shouldStop })
    }

    private func count(_ tree: TempTree, _ folder: String) throws -> Int {
        try local.listDirectory(at: tree.vfsPath(folder)).count
    }

    @Test(
        "a folder copy stopped partway keeps its finished files, names them, and undo removes them"
    )
    func copyStoppedInFolder() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let report = try run(.copy, ["top"], in: tree, on: StoppingBackend(stopAfterFiles: 1))

        #expect(report.wasCancelled)
        #expect(report.outcomes.isEmpty, "the folder did not finish")
        let stopped = try #require(report.stoppedPartway)
        #expect(stopped.source == tree.vfsPath("top"))
        #expect(stopped.landedAt == tree.vfsPath("dest/top"))
        #expect(try count(tree, "dest/top") == 1, "the file that finished stays")

        let record = try #require(UndoRecord.transfer(kind: .copy, report: report))
        #expect(record.label == .copy)
        #expect(
            record.steps == [
                .removeCopy(source: tree.vfsPath("top"), copy: tree.vfsPath("dest/top"))
            ]
        )
        #expect(UndoJournal.revert(record, using: local).failures.isEmpty)
        #expect(throws: VFSError.self) { try local.stat(at: tree.vfsPath("dest/top")) }
        #expect(try count(tree, "top") == 3)
    }

    @Test(
        "a move stopped partway keeps its source whole, is not read as moved, and undo removes the copy"
    )
    func moveStoppedInFolder() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let backend = StoppingBackend(stopAfterFiles: 2, crossVolume: true)
        let report = try run(.move, ["top"], in: tree, on: backend)

        #expect(report.wasCancelled)
        #expect(report.outcomes.isEmpty)
        #expect(try count(tree, "top") == 3, "a move removes its source only once the item is whole")
        #expect(try count(tree, "dest/top") == 2)
        // A search row for the folder stays, since its file never left.
        #expect(SearchSnapshot.changes(made: report, by: .move).isEmpty)

        let record = try #require(UndoRecord.transfer(kind: .move, report: report))
        #expect(record.label == .move)
        #expect(
            record.steps == [
                .removeCopy(source: tree.vfsPath("top"), copy: tree.vfsPath("dest/top"))
            ]
        )
        #expect(UndoJournal.revert(record, using: local).failures.isEmpty)
        #expect(throws: VFSError.self) { try local.stat(at: tree.vfsPath("dest/top")) }
        #expect(try count(tree, "top") == 3)
    }

    @Test("the items that finished and the one stopped partway are undone together")
    func finishedAndStopped() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let report = try run(
            .copy,
            ["first.txt", "top"],
            in: tree,
            on: StoppingBackend(stopAfterFiles: 2)
        )

        #expect(report.outcomes.map(\.landedAt) == [tree.vfsPath("dest/first.txt")])
        let record = try #require(UndoRecord.transfer(kind: .copy, report: report))
        #expect(record.steps == [
            .removeCopy(source: tree.vfsPath("first.txt"), copy: tree.vfsPath("dest/first.txt")),
            .removeCopy(source: tree.vfsPath("top"), copy: tree.vfsPath("dest/top"))
        ])
    }

    /// The backend removes a half-written file itself, so a lone file leaves nothing, and a record
    /// would put an Undo in the menu that does nothing.
    @Test("a lone file stopped mid-write leaves nothing, so nothing is recorded")
    func loneFileStopped() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        try tree.writeFile("big.bin", bytes: 3 << 20)
        let report = try run(.copy, ["big.bin"], in: tree, on: StoppingBackend(stopAfterChunks: 1))

        #expect(report.wasCancelled)
        #expect(report.stoppedPartway == nil)
        #expect(UndoRecord.transfer(kind: .copy, report: report) == nil)
        #expect(throws: VFSError.self) { try local.stat(at: tree.vfsPath("dest/big.bin")) }
    }

    @Test("a copy nobody stopped names nothing partway, and its record is the finished items' alone")
    func uninterrupted() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let report = try run(.copy, ["first.txt", "top"], in: tree, on: StoppingBackend())

        #expect(report.succeeded)
        #expect(report.stoppedPartway == nil)
        let record = try #require(UndoRecord.transfer(kind: .copy, report: report))
        let finished = try #require(UndoRecord.transfer(kind: .copy, outcomes: report.outcomes))
        #expect(record.steps == finished.steps)
    }
}

/// `LocalBackend` with cloning refused, so a folder is copied file by file, and a stop that trips
/// after a given number of files or chunks; with `crossVolume`, every rename fails as `EXDEV`, so a
/// move copies and then removes, as it does between two disks.
private final class StoppingBackend: VFSBackend, @unchecked Sendable {
    private let inner = LocalBackend()
    private let lock = NSLock()
    private let stopAfterFiles: Int?
    private let stopAfterChunks: Int?
    private let crossVolume: Bool
    private var files = 0
    private var chunks = 0

    init(stopAfterFiles: Int? = nil, stopAfterChunks: Int? = nil, crossVolume: Bool = false) {
        self.stopAfterFiles = stopAfterFiles
        self.stopAfterChunks = stopAfterChunks
        self.crossVolume = crossVolume
    }

    var shouldStop: Bool {
        lock.withLock {
            stopAfterFiles.map { files >= $0 } == true || stopAfterChunks.map { chunks >= $0 } == true
        }
    }

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        if crossVolume { throw VFSError.io(path: source, code: EXDEV) }
        try inner.moveItem(at: source, to: destination)
    }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool { false }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try inner.copyFile(
            at: source,
            to: destination,
            progress: { delta in
                lock.withLock { chunks += 1 }
                progress(delta)
            },
            isCancelled: isCancelled
        )
        lock.withLock { files += 1 }
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }
}
