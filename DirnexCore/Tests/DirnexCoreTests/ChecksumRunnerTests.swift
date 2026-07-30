import Foundation
import Testing

@testable import DirnexCore

/// End-to-end tests for the queued checksum engine (PLAN.md §M14 Slice 2) — the walk, the manifest
/// it writes, the verdict it returns, and cancellation.
///
/// Every expected digest below came from the *system* tools over the same bytes (`shasum -a 256`,
/// `md5 -q`, `/usr/bin/crc32`), never from this engine: a fixture the engine computed would only
/// prove it agrees with itself.
@Suite("ChecksumRunner")
struct ChecksumRunnerTests {
    let backend = LocalBackend()

    /// `shasum -a 256` over the exact bytes each helper writes.
    private enum Digest {
        static let alpha = "b6a98d9ce9a2d9149288fa3df42d377c3e42737afdcdaf714e33c0a100b51060"
        static let beta = "1e6f53bf8c3e3704ca99c5e692d8745b54ed7ec0d83064484a5fb1ce6c7355a8"
        static let nested = "370a8c04b8a65bb4494275eec227f1b694db04c76da6b0b8ae88ed1ab19790a3"
    }

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try backend.stat(at: tree.vfsPath(relative))
    }

    private func createOperation(
        _ tree: TempTree,
        sources: [String],
        manifest: String,
        algorithm: ChecksumAlgorithm = .sha256
    ) throws -> FileOperation {
        FileOperation(
            kind: .checksum(
                .create(manifest: tree.vfsPath(manifest), algorithm: algorithm)
            ),
            sources: try sources.map { try stat(tree, $0) },
            destinationDirectory: tree.vfsPath()
        )
    }

    private func verifyOperation(_ tree: TempTree, manifest: String) -> FileOperation {
        FileOperation(
            kind: .checksum(.verify(manifest: tree.vfsPath(manifest))),
            sources: [],
            destinationDirectory: tree.vfsPath()
        )
    }

    private func created(_ report: OperationReport) throws -> ChecksumCreationSummary {
        guard case let .created(summary)? = report.checksum else {
            Issue.record("expected a creation summary, got \(String(describing: report.checksum))")
            throw CancellationError()
        }
        return summary
    }

    private func verified(_ report: OperationReport) throws -> ChecksumVerificationReport {
        guard case let .verified(verdict)? = report.checksum else {
            Issue.record(
                "expected a verification report, got \(String(describing: report.checksum))"
            )
            throw CancellationError()
        }
        return verdict
    }

    private func status(_ verdict: ChecksumVerificationReport, _ name: String) -> ChecksumEntryStatus? {
        verdict.entries.first { $0.name == name }?.status
    }

    // MARK: - Create

    @Test("writes a GNU manifest whose digests match the system tool")
    func createsManifest() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")
        try tree.writeFile("b.txt", contents: "beta contents\n")

        let report = ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt", "b.txt"], manifest: "files.sha256"),
            using: backend
        )
        let summary = try created(report)

        #expect(summary.writtenCount == 2)
        #expect(summary.isComplete)
        #expect(report.succeeded)
        let text = try String(contentsOfFile: tree.path("files.sha256"), encoding: .utf8)
        #expect(text == "\(Digest.alpha)  a.txt\n\(Digest.beta)  b.txt\n")
    }

    @Test("descends into a selected directory and names files relative to the manifest")
    func createsRecursively() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("sub/deeper")
        try tree.writeFile("a.txt", contents: "alpha\n")
        try tree.writeFile("sub/deeper/c.txt", contents: "nested\n")

        let report = ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt", "sub"], manifest: "files.sha256"),
            using: backend
        )
        #expect(try created(report).writtenCount == 2)
        let text = try String(contentsOfFile: tree.path("files.sha256"), encoding: .utf8)
        #expect(text.contains("\(Digest.nested)  sub/deeper/c.txt\n"))
    }

    @Test("CRC32 is written in .sfv form, digest matching /usr/bin/crc32")
    func createsSFV() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")

        let report = ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt"], manifest: "a.txt.sfv", algorithm: .crc32),
            using: backend
        )
        #expect(try created(report).algorithm == .crc32)
        let text = try String(contentsOfFile: tree.path("a.txt.sfv"), encoding: .utf8)
        #expect(text == "a.txt 9f606eec\n")
    }

    @Test("a manifest never lists itself, even when the pane's selection includes it")
    func manifestExcludesItself() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")
        // The file exists before the run — a re-run over a directory that already has one.
        try tree.writeFile("files.sha256", contents: "stale\n")

        let operation = FileOperation(
            kind: .checksum(.create(manifest: tree.vfsPath("files.sha256"), algorithm: .sha256)),
            sources: [try stat(tree, "a.txt"), try stat(tree, "files.sha256")],
            destinationDirectory: tree.vfsPath()
        )
        #expect(try created(ChecksumRunner.run(operation, using: backend)).writtenCount == 1)
        let text = try String(contentsOfFile: tree.path("files.sha256"), encoding: .utf8)
        #expect(!text.contains("files.sha256"))
    }

    @Test("an unreadable file is named as skipped rather than silently omitted")
    func createNamesSkippedFiles() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")
        try tree.writeFile("locked.txt", contents: "secret\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: tree.path("locked.txt")
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: tree.path("locked.txt")
            )
        }

        let summary = try created(ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt", "locked.txt"], manifest: "files.sha256"),
            using: backend
        ))
        #expect(summary.writtenCount == 1)
        #expect(!summary.isComplete)
        #expect(summary.skipped.map(\.name) == ["locked.txt"])
        #expect(summary.skipped.first?.status == .unreadable)
    }

    // MARK: - Round trip

    @Test("a manifest Dirnex wrote verifies clean against the files it describes")
    func roundTrips() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("sub")
        try tree.writeFile("a.txt", contents: "alpha\n")
        try tree.writeFile("sub/c.txt", contents: "nested\n")

        _ = ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt", "sub"], manifest: "files.sha256"),
            using: backend
        )
        let verdict = try verified(
            ChecksumRunner.run(verifyOperation(tree, manifest: "files.sha256"), using: backend)
        )

        #expect(verdict.isVerified)
        #expect(verdict.okCount == 2)
        #expect(verdict.extraCount == 0) // the manifest itself must not count as extra
    }

    // MARK: - Guards

    @Test("a non-local job fails fast rather than half-working")
    func refusesNonLocalPaths() {
        let operation = FileOperation(
            kind: .checksum(
                .verify(
                    manifest: VFSPath(
                        backend: .archive(forArchiveAt: "/tmp/a.zip"),
                        path: "/files.sha256"
                    )
                )
            ),
            sources: [],
            destinationDirectory: VFSPath(backend: .archive(forArchiveAt: "/tmp/a.zip"), path: "/")
        )
        #expect(ChecksumRunner.run(operation, using: backend).checksum == .failed(.needsLocalFile))
    }

    @Test("a copy operation handed to the checksum runner does nothing")
    func ignoresForeignKinds() {
        let operation = FileOperation(
            kind: .copy,
            sources: [],
            destinationDirectory: .local("/tmp")
        )
        let report = ChecksumRunner.run(operation, using: backend)
        #expect(report.checksum == nil)
        #expect(report.completedItems == 0)
    }

    // MARK: - Progress and cancellation

    @Test("progress is determinate from the first update")
    func reportsDeterminateProgress() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("big.bin", bytes: 512 * 1024)

        let updates = Locked<[OperationProgress]>([])
        _ = ChecksumRunner.run(
            try createOperation(tree, sources: ["big.bin"], manifest: "files.sha256"),
            using: backend,
            onProgress: { progress in updates.withLock { $0.append(progress) } }
        )
        let seen = updates.withLock { $0 }
        // The RHS is a typed literal, never `512 * 1024`: an arithmetic right-hand side against an
        // `Int64?` resolves to a different numeric type and fails while both sides *display* as
        // 524288 (docs/NOTES.md, "Testing").
        let expected: Int64 = 524_288
        #expect(seen.first?.totalBytes == expected)
        #expect(seen.last?.completedBytes == expected)
        #expect(seen.last?.fraction == 1)
    }

    @Test("cancelling a create leaves no manifest behind")
    func cancelledCreateWritesNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")

        let report = ChecksumRunner.run(
            try createOperation(tree, sources: ["a.txt"], manifest: "files.sha256"),
            using: backend,
            isCancelled: { true }
        )
        #expect(report.wasCancelled)
        #expect(report.checksum == nil)
        // A half-written checksum file is worse than none: it verifies clean while covering a
        // fraction of the tree.
        #expect(!FileManager.default.fileExists(atPath: tree.path("files.sha256")))
    }
}

/// A tiny mutex for collecting callback output from a `@Sendable` closure.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
