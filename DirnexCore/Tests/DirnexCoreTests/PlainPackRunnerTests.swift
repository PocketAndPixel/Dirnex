import Foundation
import Testing

@testable import DirnexCore

/// The queued **plain** pack (PLAN.md §4 ▸ *Smaller than a milestone*) — what reaches the archive,
/// what reaches the report, and the two things it came to the queue for: a determinate bar and a
/// Stop that reaches the process.
///
/// `bsdtar` itself is not here. The writer is a seam by design (``PlainPackWriting``), so what these
/// tests measure is the runner's own job — the walk that supplies the denominator, the mapping from
/// a SIGINFO sample to the queue's progress, the delivery, and which failures are whose. Whether
/// `bsdtar` really answers a signal is a fact about the tool, measured against the tool and recorded
/// in ``BsdtarProgress``; whether the app's spawner really relays it is a live check.
@Suite("PlainPackRunner")
struct PlainPackRunnerTests {
    /// A stand-in `bsdtar`: writes bytes at the path it was given, and reports whatever samples the
    /// test handed it before doing so.
    private struct FakeWriter: PlainPackWriting {
        var samples: [BsdtarProgressSample] = []
        var archiveBytes = 64
        var failure: (any Error)?
        /// Recorded so a test can prove the runner asked for what the job described.
        let seen = Recorded<[PlainPackRequest]>([])

        func pack(
            _ request: PlainPackRequest,
            onProgress: @escaping @Sendable (BsdtarProgressSample) -> Void,
            isCancelled _: @escaping @Sendable () -> Bool
        ) throws {
            seen.withValue { $0.append(request) }
            for sample in samples { onProgress(sample) }
            if let failure { throw failure }
            FileManager.default.createFile(
                atPath: request.archiveOnDiskPath,
                contents: Data(repeating: 0x7A, count: archiveBytes)
            )
        }
    }

    private func operation(
        _ tree: TempTree,
        names: [String],
        archive: VFSPath,
        format: ArchivePacking.Format = .zip
    ) -> FileOperation {
        FileOperation(
            kind: .plainPack(
                PlainPackJob(
                    sources: PackSource.all(inDirectory: tree.root.path, names: names),
                    archive: archive,
                    format: format
                )
            ),
            sources: [],
            destinationDirectory: tree.vfsPath()
        )
    }

    private func summary(_ report: OperationReport) throws -> PackSummary {
        guard case let .created(summary)? = report.pack else {
            Issue.record("expected a pack summary, got \(String(describing: report.pack))")
            throw CancellationError()
        }
        return summary
    }

    // MARK: - The ordinary local pack

    @Test("writes the archive where it was asked for and reports what went in")
    func writesLocally() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")
        try tree.writeFile("beta.txt", contents: "beta")

        let archive = tree.vfsPath("out.zip")
        let writer = FakeWriter()
        let report = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt", "beta.txt"], archive: archive),
            using: LocalBackend(),
            writer: writer
        )

        #expect(report.succeeded)
        let summary = try summary(report)
        #expect(summary.archive == archive)
        #expect(summary.itemCount == 2)
        #expect(summary.byteSize == 64)
        // A plain pack is not encrypted and hides no names, and the window's status line reads both
        // — so they are stated rather than left to a default nobody set.
        #expect(summary.encryption == .none)
        #expect(summary.namePrivacy == .visible)
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    /// The format is the whole reason the plain path exists — libarchive's writer can only produce
    /// zip — so it has to survive the trip from the sheet to the tool.
    @Test("the job's format reaches the writer")
    func formatReachesTheWriter() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        let writer = FakeWriter()
        _ = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: tree.vfsPath("out.tgz"), format: .tarGz),
            using: LocalBackend(),
            writer: writer
        )
        let asked = try #require(writer.seen.withValue { $0.first })
        let names = asked.sources.map(\.name)
        #expect(asked.format == .tarGz)
        #expect(names == ["alpha.txt"])
    }

    // MARK: - The bar

    /// `bsdtar` says nothing until it is asked, and the first ask is a poll interval away — so the
    /// job has to state its denominator itself or the bar is empty for the first second of every
    /// pack, which reads as a job that has not started.
    @Test("the bar is determinate from its first update")
    func determinateFromTheFirstUpdate() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: String(repeating: "a", count: 500))

        let updates = Recorded<[OperationProgress]>([])
        _ = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: tree.vfsPath("out.zip")),
            using: LocalBackend(),
            writer: FakeWriter(),
            onProgress: { progress in updates.withValue { $0.append(progress) } }
        )

        let first = try #require(updates.withValue { $0.first })
        #expect(first.totalBytes == 500)
        #expect(first.completedBytes == 0)
    }

    @Test("a sample's bytes read become the bar's numerator")
    func samplesDriveTheBar() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: String(repeating: "a", count: 1000))

        var writer = FakeWriter()
        writer.samples = [
            BsdtarProgressSample(
                filesRead: 0,
                bytesRead: 400,
                bytesWritten: 90,
                currentItem: "alpha.txt"
            )
        ]
        let updates = Recorded<[OperationProgress]>([])
        _ = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: tree.vfsPath("out.zip")),
            using: LocalBackend(),
            writer: writer,
            onProgress: { progress in updates.withValue { $0.append(progress) } }
        )

        // The *read* side, never the written one: the archive's own growth has no denominator until
        // the compression ratio is known, which is at the end.
        #expect(
            updates.withValue { $0.contains { $0.completedBytes == 400 && $0.totalBytes == 1000 } }
        )
        #expect(!updates.withValue { $0.contains { $0.completedBytes == 90 } })
    }

    /// The walk counts regular files' bytes and `bsdtar` counts everything it reads, so a tree of
    /// many small files can report past the total. A bar that overshoots reads as a job that has
    /// lost track of itself.
    @Test("a sample past the total is clamped")
    func clampsAnOvershoot() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        var writer = FakeWriter()
        writer.samples = [
            BsdtarProgressSample(filesRead: 9, bytesRead: 999_999, bytesWritten: 1, currentItem: nil)
        ]
        let updates = Recorded<[OperationProgress]>([])
        _ = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: tree.vfsPath("out.zip")),
            using: LocalBackend(),
            writer: writer,
            onProgress: { progress in updates.withValue { $0.append(progress) } }
        )

        #expect(updates.withValue { $0.allSatisfy { $0.completedBytes <= $0.totalBytes } })
        #expect(updates.withValue { $0.allSatisfy { $0.completedItems <= $0.totalItems } })
    }

    // MARK: - Stopping and failing

    @Test("a stopped pack is cancelled, not failed")
    func cancellation() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        var writer = FakeWriter()
        writer.failure = CancellationError()
        let report = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: tree.vfsPath("out.zip")),
            using: LocalBackend(),
            writer: writer
        )

        #expect(report.wasCancelled)
        #expect(report.pack == nil)
        #expect(report.failures.isEmpty)
    }

    @Test("a failed pack reports the archive's own path")
    func failure() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        let archive = tree.vfsPath("out.zip")
        var writer = FakeWriter()
        writer.failure = VFSError.unsupported(.archiveCreateFailed(archive: "out.zip"))
        let report = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: archive),
            using: LocalBackend(),
            writer: writer
        )

        #expect(!report.succeeded)
        let failedPaths = report.failures.map(\.path)
        #expect(failedPaths == [archive])
        #expect(report.pack == nil)
    }

    /// A queue that accepted the job and did nothing is the quietest bug available, and this project
    /// has paid for that shape before (docs/NOTES.md ▸ Design lessons, on a seam whose default is
    /// "can't help, do it the slow way").
    @Test("no writer at all is reported, not silently skipped")
    func missingWriterIsReported() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        let report = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: tree.vfsPath("out.zip")),
            using: LocalBackend(),
            writer: nil
        )

        #expect(!report.succeeded)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.error == .unsupported(.archiveToolUnavailableForCreate))
    }

    /// The narrowness control on the dispatch guard: this runner must not run somebody else's job.
    @Test("another kind of job is not this runner's")
    func wrongKind() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let report = PlainPackRunner.run(
            FileOperation(kind: .copy, sources: [], destinationDirectory: tree.vfsPath()),
            using: LocalBackend(),
            writer: FakeWriter()
        )
        #expect(report.pack == nil)
        #expect(report.failures.isEmpty)
    }
}

/// A plain pack whose destination is not on this disk (PLAN.md §4 ▸ *Smaller than a milestone*).
///
/// The half the queue was wanted for: until 2026-08-30 the archive went up with no bar and no Stop,
/// reported by a status line, while the encrypted twin put both halves on the queue.
@Suite("PlainPackRunner ▸ a destination on a server")
struct PlainPackRunnerRemoteDestinationTests {
    private struct FakeWriter: PlainPackWriting {
        let archiveBytes: Int
        func pack(
            _ request: PlainPackRequest,
            onProgress _: @escaping @Sendable (BsdtarProgressSample) -> Void,
            isCancelled _: @escaping @Sendable () -> Bool
        ) throws {
            FileManager.default.createFile(
                atPath: request.archiveOnDiskPath,
                contents: Data(repeating: 0x7A, count: archiveBytes)
            )
        }
    }

    private func operation(_ tree: TempTree, names: [String], archive: VFSPath) -> FileOperation {
        FileOperation(
            kind: .plainPack(
                PlainPackJob(
                    sources: PackSource.all(inDirectory: tree.root.path, names: names),
                    archive: archive,
                    format: .zip
                )
            ),
            sources: [],
            destinationDirectory: tree.vfsPath()
        )
    }

    @Test("an archive bound for a server is built here and transferred, leaving no temp behind")
    func remoteDestinationIsUploaded() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        let store = FakeRemoteStore([:])
        let destination = store.path("/backups/out.zip")
        let report = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: destination),
            using: store,
            writer: FakeWriter(archiveBytes: 128)
        )

        #expect(report.succeeded)
        let uploaded = try #require(store.data(at: "/backups/out.zip"))
        #expect(uploaded.count == 128)
        // Nothing of the build survives: a cancelled or finished transfer must not leave somebody's
        // whole archive in a temp directory they will never look in.
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.path)
            .filter { $0.hasSuffix("out.zip") }
        #expect(leftovers.isEmpty)
    }

    /// The upload's bytes are **added** to the denominator rather than replacing it, so the bar
    /// grows once at the transition and runs on. Leaving the total alone would park a full bar for
    /// the length of a network transfer, and starting a fresh one walks the aggregate backwards.
    @Test("the bar grows to include the upload rather than parking full")
    func theBarIncludesTheUpload() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: String(repeating: "a", count: 100))

        let store = FakeRemoteStore([:])
        let updates = Recorded<[OperationProgress]>([])
        let report = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: store.path("/out.zip")),
            using: store,
            writer: FakeWriter(archiveBytes: 400),
            onProgress: { progress in updates.withValue { $0.append(progress) } }
        )

        #expect(report.succeeded)
        #expect(updates.withValue { $0.first }?.totalBytes == 100)
        // 100 read + 400 uploaded, and the job's own completed count agrees with it.
        let peak = updates.withValue { $0.map(\.totalBytes).max() }
        #expect(peak == 500)
        #expect(report.completedBytes == 500)
    }

    @Test("a refused upload reports the backend's own reason, not the pack vocabulary")
    func refusedUpload() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        let store = FakeRemoteStore([:], refusingUploadsTo: ["/out.zip"])
        let destination = store.path("/out.zip")
        let report = PlainPackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: destination),
            using: store,
            writer: FakeWriter(archiveBytes: 64)
        )

        #expect(!report.succeeded)
        #expect(report.pack == nil)
        // The archive really was written; what failed was putting it somewhere. So the failure is
        // the backend's, about the path it refused.
        let failedPaths = report.failures.map(\.path)
        #expect(failedPaths == [destination])
    }
}

/// A value two threads may touch, for a test that collects what a `@Sendable` progress closure
/// reported.
private final class Recorded<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
