import Foundation
import Testing

@testable import DirnexCore

/// A copy seen file by file (``TransferFiles``, PLAN.md §M41): the file being written now at any
/// depth with its own bytes, and how many of the job's files are done — what the progress dialog
/// draws as its upper bar and as "file 34 of 340".
///
/// Measured before the change on a folder of 3 000 4 KB files and one of 200 MB: 29 updates, none
/// naming a small file, because the engine reported only every 8 MiB. The clock is what fixes that,
/// so the naming tests run under an injected one, and the frozen-clock test is their negative
/// control: same tree, same path, and no file inside the folder is named.
@Suite("CopyEngine file-by-file progress")
struct CopyEngineFileProgressTests {
    /// A folder two levels deep holding a symlink, beside a loose file: every shape a file count
    /// has to agree about. Four files: `one.bin`, `sub/two.bin`, `link` and `loose.bin`.
    private func tree() throws -> TempTree {
        let tree = try TempTree()
        try tree.makeDir("folder/sub")
        try tree.writeFile("folder/one.bin", bytes: 3000)
        try tree.writeFile("folder/sub/two.bin", bytes: 5000)
        try tree.symlink("folder/link", to: "one.bin")
        try tree.writeFile("loose.bin", bytes: 100)
        try tree.makeDir("dest")
        return tree
    }

    private func operation(_ kind: FileOperation.Kind = .copy, in tree: TempTree) throws -> FileOperation {
        let local = LocalBackend()
        return FileOperation(
            kind: kind,
            sources: [
                try local.stat(at: tree.vfsPath("folder")),
                try local.stat(at: tree.vfsPath("loose.bin"))
            ],
            destinationDirectory: tree.vfsPath("dest")
        )
    }

    @Test("counts every file under the sources, at any depth, and ends with all of them done")
    func countsFilesAtAnyDepth() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let updates = ProgressLog()

        let report = CopyEngine.run(
            try operation(in: tree),
            using: ChunkedOnlyBackend(),
            onProgress: { updates.append($0) }
        )

        #expect(report.succeeded)
        let first = try #require(updates.all.first?.files)
        #expect(first.total == 4, "one.bin, sub/two.bin, link and loose.bin; no folder")
        #expect(first.completed == 0)
        let last = try #require(updates.all.last?.files)
        #expect(last.total == 4)
        #expect(last.completed == 4)
        #expect(last.current == nil, "the last source is done, so no file is being written")
        #expect(updates.all.allSatisfy { ($0.files?.completed ?? 0) <= 4 })
    }

    /// A clone, and a same-volume rename, take a whole folder in one call: there is no file to name,
    /// and all of the folder's files are done at once.
    @Test(
        "a source taken whole counts all its files at once",
        arguments: [FileOperation.Kind.copy, .move]
    )
    func wholeSourceCountsAtOnce(kind: FileOperation.Kind) throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let updates = ProgressLog()

        let report = CopyEngine.run(
            try operation(kind, in: tree),
            using: LocalBackend(),
            onProgress: { updates.append($0) },
            uptime: Self.ticking()
        )

        #expect(report.succeeded)
        #expect(updates.all.last?.files?.completed == 4)
        #expect(updates.all.allSatisfy { $0.files?.current == nil })
    }

    @Test("names the file being written inside a folder, with its own bytes")
    func namesTheFileInsideAFolder() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let updates = ProgressLog()

        _ = CopyEngine.run(
            try operation(in: tree),
            using: ChunkedOnlyBackend(),
            onProgress: { updates.append($0) },
            uptime: Self.ticking()
        )

        let one = updates.all.compactMap(\.files).filter { $0.current == tree.vfsPath(
            "folder/one.bin"
        ) }
        let two = updates.all.compactMap(\.files).filter { $0.current == tree.vfsPath(
            "folder/sub/two.bin"
        ) }
        #expect(!one.isEmpty)
        #expect(!two.isEmpty)
        #expect(one.allSatisfy { $0.currentTotalBytes == 3000 })
        #expect(two.allSatisfy { $0.currentTotalBytes == 5000 })
        // It starts at zero and reaches the file's size, which is what the dialog's upper bar draws.
        #expect(one.first?.currentCompletedBytes == 0)
        #expect(one.contains { $0.currentCompletedBytes == 3000 && $0.currentFraction == 1 })
        #expect(two.contains { $0.currentCompletedBytes == 5000 })
    }

    /// The negative control for the test above: with the clock stopped, only the byte threshold and
    /// the top-level boundaries report, and neither names a small file inside a folder. This is the
    /// engine as it was before §M41, and it is why the clock is there.
    @Test("with the clock stopped, no file inside the folder is named")
    func frozenClockNamesNothing() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let updates = ProgressLog()

        let report = CopyEngine.run(
            try operation(in: tree),
            using: ChunkedOnlyBackend(),
            onProgress: { updates.append($0) },
            uptime: { 42 }
        )

        #expect(report.succeeded)
        #expect(updates.all.allSatisfy { $0.files?.current == nil })
        #expect(updates.all.last?.files?.completed == 4, "the count is right either way")
    }

    /// A folder that fails partway is taken back as a whole, files as well as bytes, so a skip
    /// leaves the count at what really landed rather than at what was tried. The second file
    /// written fails rather than one named, since the listing's order is the file system's: either
    /// way one of the folder's files has landed by then.
    @Test("a failed source's files are taken back")
    func failedSourceIsTakenBack() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let updates = ProgressLog()

        let report = CopyEngine.run(
            try operation(in: tree),
            using: ChunkedOnlyBackend(failingCopy: 2),
            onError: { _ in .skip },
            onProgress: { updates.append($0) },
            uptime: Self.ticking()
        )

        #expect(report.failures.map(\.path) == [tree.vfsPath("folder")])
        // The folder got as far as a file before the second one failed; it is not counted.
        #expect(updates.all.contains { ($0.files?.completed ?? 0) > 0 && $0.files?.current != nil })
        #expect(updates.all.last?.files?.completed == 1, "loose.bin alone")
        #expect(updates.all.last?.files?.total == 4)
    }

    /// A clock that moves a second on every reading, so every chance to report is taken.
    private static func ticking() -> @Sendable () -> TimeInterval {
        let ticks = ProgressLog.Counter()
        return { ticks.next() }
    }
}

// MARK: - Test doubles

/// Every update the engine sent, in order, from whichever thread sent it.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [OperationProgress] = []

    func append(_ update: OperationProgress) {
        lock.withLock { updates.append(update) }
    }

    var all: [OperationProgress] { lock.withLock { updates } }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0

        func next() -> TimeInterval {
            lock.withLock {
                value += 1
                return value
            }
        }
    }
}

/// `LocalBackend` with cloning refused, so the engine walks a folder and writes it file by file —
/// the path a cross-volume copy and every remote one takes — and, when asked, failing the n-th
/// file it is given to write (counting from 1).
private struct ChunkedOnlyBackend: VFSBackend {
    let failingCopy: Int?
    private let copies = ProgressLog.Counter()
    private let inner = LocalBackend()

    init(failingCopy: Int? = nil) {
        self.failingCopy = failingCopy
    }

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try inner.moveItem(at: source, to: destination)
    }

    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }
    func cloneItem(at _: VFSPath, to _: VFSPath) throws -> Bool { false }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if Int(copies.next()) == failingCopy { throw VFSError.io(path: source, code: EIO) }
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }
}
