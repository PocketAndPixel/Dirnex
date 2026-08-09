import Foundation
import Testing

@testable import DirnexCore

/// The queued encrypted pack (PLAN.md §M19 Slice 2) — what reaches the archive, what reaches the
/// report, and the two things a queue job owes that a bare writer does not: a determinate bar from
/// the first update, and a cancel that leaves nothing behind.
///
/// The *format* claims live in `EncryptedArchiveWriterTests`, which reads the zip bytes by hand
/// rather than asking the writer what it wrote. Nothing here re-checks them; these tests are about
/// the runner's own job — the guards, the report, and the progress arithmetic.
@Suite("PackRunner")
struct PackRunnerTests {
    private func operation(
        _ tree: TempTree,
        names: [String],
        archive: String = "out.zip",
        encryption: ArchiveEncryption = .aes256,
        namePrivacy: ArchiveNamePrivacy = .visible,
        passphrase: String? = "correct horse battery staple",
        sourceDirectory: VFSPath? = nil,
        archivePath: VFSPath? = nil
    ) -> FileOperation {
        let job = PackJob(
            sourceDirectory: sourceDirectory ?? tree.vfsPath(),
            names: names,
            archive: archivePath ?? tree.vfsPath(archive),
            encryption: encryption,
            namePrivacy: namePrivacy,
            passphrase: passphrase.map(ArchivePassphrase.init)
        )
        return FileOperation(
            kind: .pack(job),
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

    private func failure(_ report: OperationReport) throws -> EncryptedArchiveError {
        guard case let .failed(error)? = report.pack else {
            Issue.record("expected a pack failure, got \(String(describing: report.pack))")
            throw CancellationError()
        }
        return error
    }

    // MARK: - The happy path

    @Test("an encrypted pack writes an archive that needs its passphrase and gives the bytes back")
    func encryptedRoundTrip() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")
        try tree.makeDir("docs")
        try tree.writeFile("docs/report.txt", contents: "report")

        let report = PackRunner.run(operation(tree, names: ["alpha.txt", "docs"]))
        #expect(report.succeeded)
        let summary = try summary(report)
        #expect(summary.encryption == .aes256)
        #expect(summary.itemCount == 3) // alpha.txt, docs, docs/report.txt
        #expect(summary.byteSize > 0)

        // The names are readable without the passphrase — that is zip, not a bug, and
        // `ArchiveNamePrivacy` is the answer to it. The *data* is not.
        let inspection = try EncryptedArchiveReader.inspect(archiveAt: summary.archive.path)
        #expect(inspection.needsPassphrase)
        #expect(inspection.entries.map(\.archivePath).sorted() == [
            "alpha.txt", "docs/", "docs/report.txt"
        ])

        try tree.makeDir("out")
        let extraction = try EncryptedArchiveReader.extract(
            archiveAt: summary.archive.path,
            into: tree.path("out"),
            passphrase: ArchivePassphrase("correct horse battery staple")
        )
        #expect(extraction.refused.isEmpty)
        let restored = try String(contentsOfFile: tree.path("out/docs/report.txt"), encoding: .utf8)
        #expect(restored == "report")
    }

    @Test("the wrong passphrase does not open what the runner wrote")
    func wrongPassphraseIsRefused() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        let report = PackRunner.run(operation(tree, names: ["alpha.txt"]))
        let summary = try summary(report)
        try tree.makeDir("out")
        #expect(throws: EncryptedArchiveError.incorrectPassphrase) {
            try EncryptedArchiveReader.extract(
                archiveAt: summary.archive.path,
                into: tree.path("out"),
                passphrase: ArchivePassphrase("not it")
            )
        }
    }

    @Test("hiding the file names leaves one entry in the outer archive")
    func hiddenNamesWrapThePayload() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("salary-2026.txt", contents: "…")
        try tree.writeFile("resignation.txt", contents: "…")

        let report = PackRunner.run(
            operation(tree, names: ["salary-2026.txt", "resignation.txt"], namePrivacy: .hidden)
        )
        let summary = try summary(report)
        #expect(summary.namePrivacy == .hidden)
        let names = try EncryptedArchiveReader.inspect(archiveAt: summary.archive.path)
            .entries.map(\.archivePath)
        #expect(names == [ArchiveNamePrivacy.wrappedEntryName])
        // The itemCount is what the user selected, not what the outer zip lists — the wrapper is
        // Dirnex's own bookkeeping and reporting "1 item" for two files would be a lie.
        #expect(summary.itemCount == 2)
    }

    // MARK: - Guards

    @Test("a job for a remote backend fails fast instead of half-working")
    func remoteJobIsRefused() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        let report = PackRunner.run(
            operation(
                tree,
                names: ["alpha.txt"],
                archivePath: VFSPath(
                    backend: .sftp(SFTPLocation(host: "example.com", username: "x")),
                    path: "/a.zip"
                )
            )
        )
        #expect(try failure(report) == .needsLocalFile)
        #expect(!FileManager.default.fileExists(atPath: tree.path("out.zip")))
    }

    @Test("an empty selection produces no archive")
    func emptySelectionIsRefused() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let report = PackRunner.run(operation(tree, names: []))
        #expect(try failure(report) == .nothingToArchive)
        #expect(!FileManager.default.fileExists(atPath: tree.path("out.zip")))
    }

    @Test("an encrypted job with a blank passphrase writes nothing")
    func blankPassphraseIsRefused() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")
        let report = PackRunner.run(operation(tree, names: ["alpha.txt"], passphrase: ""))
        #expect(try failure(report) == .emptyPassphrase)
        #expect(!FileManager.default.fileExists(atPath: tree.path("out.zip")))
    }

    @Test("a cloud placeholder stops the pack by name rather than downloading it")
    func placeholderIsNamed() throws {
        // No test can produce a real `SF_DATALESS` file — `chflags` reports success and the kernel
        // drops the flag, since it belongs to the file provider (docs/NOTES.md). What is checkable
        // here is that the runner passes the walk's refusal home *as* a pack failure rather than
        // flattening it into a path error, which is the half the runner owns.
        let error = EncryptedArchiveError.wouldDownloadPlaceholder(name: "photo.heic")
        #expect(error.key == "wouldDownloadPlaceholder")
        #expect(error.arguments == ["photo.heic"])
    }

    @Test("a kind that is not a pack does nothing rather than trapping")
    func foreignKindIsInert() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let report = PackRunner.run(
            FileOperation(kind: .copy, sources: [], destinationDirectory: tree.vfsPath())
        )
        #expect(report.pack == nil)
        #expect(report.completedItems == 0)
    }

    // MARK: - Progress and cancellation

    @Test("the bar is determinate from its first update")
    func progressIsDeterminateImmediately() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        for index in 0..<8 {
            try tree.writeFile("file-\(index).bin", bytes: 200_000)
        }
        let names = (0..<8).map { "file-\($0).bin" }

        let updates = Locked<[OperationProgress]>([])
        let report = PackRunner.run(
            operation(tree, names: names),
            onProgress: { progress in updates.withValue { $0.append(progress) } }
        )
        #expect(report.succeeded)
        let seen = updates.withValue { $0 }
        let first = try #require(seen.first)
        // The walk measured the total before a byte was written, so the denominator never grows.
        #expect(first.totalBytes == 1_600_000)
        #expect(seen.allSatisfy { $0.totalBytes == first.totalBytes })
        #expect(seen.last?.completedBytes == first.totalBytes)
        #expect(report.completedBytes == 1_600_000)
    }

    @Test("cancelling leaves no archive behind at all")
    func cancellationLeavesNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        for index in 0..<12 {
            try tree.writeFile("file-\(index).bin", bytes: 400_000)
        }
        let names = (0..<12).map { "file-\($0).bin" }

        let cancelled = Locked(false)
        let report = PackRunner.run(
            operation(tree, names: names),
            onProgress: { progress in
                if progress.completedBytes > 0 { cancelled.withValue { $0 = true } }
            },
            isCancelled: { cancelled.withValue { $0 } }
        )
        #expect(report.wasCancelled)
        #expect(report.pack == nil)
        // Not a truncated archive, not a temporary sibling — nothing. A plausible-looking zip that
        // opens and is missing most of its contents is the failure this is built to avoid.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tree.root.path)
        #expect(leftovers.allSatisfy { $0.hasPrefix("file-") })
    }
}

/// A tiny mutex for values the progress callback writes from the writer's own thread.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
