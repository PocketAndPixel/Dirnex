import Foundation
import Testing

@testable import DirnexCore

/// Pulling a marked set down to real paths as a queue job (PLAN.md §M24 Slice 2).
///
/// The claims worth pinning are the ones a gesture rests on rather than the loop itself: that two
/// objects with the **same name** from different prefixes do not overwrite one another, that a run
/// keeps going past a failure and says which row failed, that a cancelled or failed transfer leaves
/// **nothing** on disk to be mistaken for a whole file, and that the report carries no `outcomes` —
/// which is what stops the undo journal offering to reverse a download into a temp directory.
@Suite("Materialize runner")
struct MaterializeRunnerTests {
    static let remote = VFSBackendID("test-remote://host")

    private func job(_ sources: [FileEntry], into root: String) -> FileOperation {
        FileOperation(kind: .materialize, sources: sources, destinationDirectory: .local(root))
    }

    /// Names the copies' directories `d0`, `d1`, … so the layout can be asserted. Production uses a
    /// UUID; what is being tested is that each file gets *its own*, not what it is called.
    private func counter() -> @Sendable () -> String {
        let next = Counter()
        return { "d\(next.take())" }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func take() -> Int { lock.withLock { defer { value += 1 }; return value } }
    }

    // MARK: - The bytes land where a gesture can read them

    @Test("every source lands under its real name in a directory of its own")
    func landsEachFileInItsOwnDirectory() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let backend = FakeRemoteBackend(store: [
            "/a/report.pdf": "left",
            "/b/report.pdf": "right"
        ])
        let sources = [backend.entry("/a/report.pdf"), backend.entry("/b/report.pdf")]

        let report = MaterializeRunner.run(
            job(sources, into: tree.root.path), using: backend, directoryName: counter()
        )

        let landed = try #require(report.materialized)
        #expect(landed.map(\.localPath) == [
            tree.path("d0/report.pdf"), tree.path("d1/report.pdf")
        ])
        #expect(try String(contentsOfFile: landed[0].localPath, encoding: .utf8) == "left")
        #expect(try String(contentsOfFile: landed[1].localPath, encoding: .utf8) == "right")
        #expect(report.succeeded)
    }

    /// The revision travels with the copy because it is what a save-back compares against before it
    /// overwrites, and the listing it came from may have been refreshed by then.
    @Test("each copy carries the revision it was taken at")
    func carriesTheRevision() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let backend = FakeRemoteBackend(store: ["/o.bin": "0123456789"])
        let entry = backend.entry("/o.bin", tag: "\"abc\"")

        let report = MaterializeRunner.run(
            job([entry], into: tree.root.path), using: backend, directoryName: counter()
        )

        let landed = try #require(report.materialized?.first)
        #expect(landed.source == entry.path)
        #expect(landed.revision == RemoteFileRevision(entry))
    }

    /// Nothing here is undoable, and the mechanism is the absence of outcomes rather than a rule
    /// somebody remembered: `UndoJournal` builds a transfer record from them, and reversing this one
    /// would mean putting back a copy the user never saw.
    @Test("a finished run produces no undo material")
    func producesNoOutcomes() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let backend = FakeRemoteBackend(store: ["/o.bin": "xyz"])

        let report = MaterializeRunner.run(
            job([backend.entry("/o.bin")], into: tree.root.path),
            using: backend,
            directoryName: counter()
        )

        #expect(report.outcomes.isEmpty)
        #expect(UndoRecord.transfer(kind: .materialize, outcomes: []) == nil)
    }

    // MARK: - Failure and cancellation

    /// Right for a checksum over forty objects and wrong for ⌥F3 — which is why the loop keeps
    /// going and the *gesture* decides, reading the failures. Both halves in one test: what got
    /// through is usable, and the row that did not is named.
    @Test("one failure does not stop the rest, and it names the row")
    func continuesPastAFailure() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let backend = FakeRemoteBackend(store: ["/ok1.bin": "aa", "/ok2.bin": "bb"])
        let missing = backend.entry("/gone.bin")
        let sources = [backend.entry("/ok1.bin"), missing, backend.entry("/ok2.bin")]

        let report = MaterializeRunner.run(
            job(sources, into: tree.root.path), using: backend, directoryName: counter()
        )

        #expect(report.materialized?.map(\.source) == [sources[0].path, sources[2].path])
        #expect(report.failures.map(\.path) == [missing.path])
        #expect(report.failures.first?.error == .notFound(missing.path))
        #expect(report.succeeded == false)
    }

    /// A truncated document renders as damage rather than as an error, so a failed transfer must
    /// leave the disk exactly as it found it — the opposite of what F5 wants from the same bytes,
    /// where the partial is what `-C -` resumes from.
    @Test("a failed transfer leaves nothing behind")
    func failedTransferLeavesNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let backend = FakeRemoteBackend(store: [:], failMidTransfer: ["/half.bin"])

        let report = MaterializeRunner.run(
            job([backend.entry("/half.bin")], into: tree.root.path),
            using: backend,
            directoryName: counter()
        )

        #expect(report.materialized?.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: tree.path("d0")) == false)
        let left = try FileManager.default.contentsOfDirectory(atPath: tree.root.path)
        #expect(left.isEmpty)
    }

    /// Stop between files: what has landed is kept and reported, and the run says it was cancelled
    /// rather than reporting a clean finish over a set it never got through.
    @Test("cancelling keeps what landed and marks the run cancelled")
    func cancellationKeepsWhatLanded() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let backend = FakeRemoteBackend(store: ["/a.bin": "aa", "/b.bin": "bb"])
        let stop = Counter()

        let report = MaterializeRunner.run(
            job([backend.entry("/a.bin"), backend.entry("/b.bin")], into: tree.root.path),
            using: backend,
            // False, then true: the first file transfers and the second never starts.
            isCancelled: { stop.take() > 0 },
            directoryName: counter()
        )

        #expect(report.wasCancelled)
        #expect(report.materialized?.count == 1)
        #expect(backend.copiedPaths == ["/a.bin"])
    }

    // MARK: - Progress

    /// Determinate from the first update, because the listing already measured every source — the
    /// same fact that let `MaterializationPlan` state the total before any of this started.
    @Test("the byte total is the set's own, known before the first transfer")
    func progressIsDeterminateFromTheStart() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let backend = FakeRemoteBackend(store: ["/a.bin": "aaaa", "/b.bin": "bbbbbb"])
        let seen = ProgressLog()

        let report = MaterializeRunner.run(
            job([backend.entry("/a.bin"), backend.entry("/b.bin")], into: tree.root.path),
            using: backend,
            onProgress: { seen.append($0) },
            directoryName: counter()
        )

        let updates = seen.all
        #expect(updates.first?.totalBytes == 10)
        #expect(updates.first?.completedBytes == 0)
        #expect(updates.allSatisfy { $0.totalBytes == 10 })
        #expect(report.completedBytes == 10)
    }

    /// A dispatch that reaches the wrong runner, or a job pointed at a destination that is not on
    /// this disk, degrades to "nothing happened" rather than trapping — every other runner's rule.
    @Test("a mismatched job returns an empty report rather than trapping")
    func mismatchedJobIsEmpty() {
        let backend = FakeRemoteBackend(store: [:])
        let elsewhere = FileOperation(
            kind: .materialize,
            sources: [],
            destinationDirectory: VFSPath(backend: Self.remote, path: "/tmp")
        )
        let wrongKind = FileOperation(
            kind: .copy, sources: [], destinationDirectory: .local("/tmp")
        )

        #expect(MaterializeRunner.run(elsewhere, using: backend).materialized == nil)
        #expect(MaterializeRunner.run(wrongKind, using: backend).materialized == nil)
    }

    // MARK: - Through the queue

    /// The slice's actual claim — "an N-file fetch *is* a `FileOperation`" — which no test of the
    /// runner can make: what is being checked here is that `FileOperationQueue` dispatches the new
    /// kind at all, that the copies ride home on the report the window already watches, and that
    /// the job reaches a terminal state like every other. A dispatch that fell through would return
    /// `.empty` and look like a job that simply did nothing.
    @Test("the queue runs a materialize job and carries the copies home on its report")
    func runsThroughTheQueue() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let backend = FakeRemoteBackend(store: ["/a.bin": "aaaa", "/b.bin": "bb"])
        let queue = FileOperationQueue(backend: backend)

        let id = await queue.enqueue(
            job([backend.entry("/a.bin"), backend.entry("/b.bin")], into: tree.root.path)
        )
        await queue.waitUntilIdle()

        let snapshot = await queue.snapshot()
        let finished = try #require(snapshot.jobs.first { $0.id == id })
        #expect(finished.status == .finished)
        let landed = try #require(finished.report?.materialized)
        #expect(landed.count == 2)
        #expect(landed.allSatisfy { FileManager.default.fileExists(atPath: $0.localPath) })
        #expect(finished.report?.succeeded == true)
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var updates: [OperationProgress] = []
        func append(_ update: OperationProgress) { lock.withLock { updates.append(update) } }
        var all: [OperationProgress] { lock.withLock { updates } }
    }
}

/// A backend whose objects live in memory on another "host": every path but `.local` is remote, and
/// a copy out of it writes the bytes the store holds.
private final class FakeRemoteBackend: VFSBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let store: [String: String]
    private let failMidTransfer: Set<String>
    private var copied: [String] = []

    init(store: [String: String], failMidTransfer: Set<String> = []) {
        self.store = store
        self.failMidTransfer = failMidTransfer
    }

    var copiedPaths: [String] { lock.withLock { copied } }

    var id: VFSBackendID { MaterializeRunnerTests.remote }
    var capabilities: VFSCapabilities { [.read] }

    func entry(_ path: String, tag: String? = nil) -> FileEntry {
        let full = VFSPath(backend: id, path: path)
        return FileEntry(
            path: full,
            name: full.lastComponent,
            kind: .file,
            byteSize: Int64(store[path]?.utf8.count ?? 0),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_600_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 1,
            entityTag: tag
        )
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        lock.withLock { copied.append(source.path) }
        if failMidTransfer.contains(source.path) {
            // Write a partial first, exactly as an interrupted transfer would, so "leaves nothing
            // behind" is a claim about cleanup rather than about never having started.
            try? Data("half".utf8).write(to: URL(fileURLWithPath: destination.path))
            throw VFSError.io(path: source, code: 5)
        }
        guard let contents = store[source.path] else { throw VFSError.notFound(source) }
        try Data(contents.utf8).write(to: URL(fileURLWithPath: destination.path))
        progress(Int64(contents.utf8.count))
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        guard store[path.path] != nil else { throw VFSError.notFound(path) }
        return entry(path.path)
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }
}
