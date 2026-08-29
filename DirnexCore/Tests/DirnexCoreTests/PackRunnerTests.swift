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
        sourceDirectory: String? = nil,
        archivePath: VFSPath? = nil
    ) -> FileOperation {
        let job = PackJob(
            sources: PackSource.all(
                inDirectory: sourceDirectory ?? tree.root.path,
                names: names
            ),
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

    /// ``PackRunner/run(_:using:onProgress:isCancelled:)`` with a backend supplied.
    ///
    /// A local destination never asks the backend anything — the writer lands on the path itself —
    /// so the ordinary tests hand over a `LocalBackend` and the remote ones hand over the fake that
    /// records what arrived. Defaulted here rather than on the runner, because the queue always has
    /// a backend and a default there would let a dispatch quietly forget to pass one.
    private func pack(
        _ operation: FileOperation,
        using backend: any VFSBackend = LocalBackend(),
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> OperationReport {
        PackRunner.run(operation, using: backend, onProgress: onProgress, isCancelled: isCancelled)
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

        let report = pack(operation(tree, names: ["alpha.txt", "docs"]))
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

        let report = pack(operation(tree, names: ["alpha.txt"]))
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

        let report = pack(
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

    @Test("sources gathered from several directories all land, under their own bare names")
    func scatteredSourcesArePacked() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        // The shape a staged pack has: `MaterializeRunner` gives each downloaded object a directory
        // of its own, so a set fetched off a server is never one folder's worth (PLAN.md §M24
        // Slice 6). Two files of the same *name* in different directories is the case that made
        // that layout necessary in the first place, so it is the one worth packing here.
        try tree.makeDir("stage-1")
        try tree.makeDir("stage-2")
        try tree.writeFile("stage-1/alpha.txt", contents: "from one")
        try tree.writeFile("stage-2/beta.txt", contents: "from two")

        let job = PackJob(
            sources: [
                PackSource(directory: tree.path("stage-1"), name: "alpha.txt"),
                PackSource(directory: tree.path("stage-2"), name: "beta.txt")
            ],
            archive: tree.vfsPath("out.zip"),
            encryption: .aes256,
            passphrase: ArchivePassphrase("correct horse battery staple")
        )
        let report = pack(
            FileOperation(kind: .pack(job), sources: [], destinationDirectory: tree.vfsPath())
        )
        let summary = try summary(report)
        #expect(summary.itemCount == 2)

        // Bare names, and no trace of where either was staged: what the recipient sees is what the
        // user marked, which is the whole reason `PackSource` keeps one name rather than two.
        let entries = try EncryptedArchiveReader.inspect(archiveAt: summary.archive.path)
            .entries.map(\.archivePath)
        #expect(entries.sorted() == ["alpha.txt", "beta.txt"])

        try tree.makeDir("out")
        _ = try EncryptedArchiveReader.extract(
            archiveAt: summary.archive.path,
            into: tree.path("out"),
            passphrase: ArchivePassphrase("correct horse battery staple")
        )
        #expect(
            try String(contentsOfFile: tree.path("out/alpha.txt"), encoding: .utf8) == "from one"
        )
        #expect(
            try String(contentsOfFile: tree.path("out/beta.txt"), encoding: .utf8) == "from two"
        )
    }

    // MARK: - Guards

    @Test("an empty selection produces no archive")
    func emptySelectionIsRefused() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let report = pack(operation(tree, names: []))
        #expect(try failure(report) == .nothingToArchive)
        #expect(!FileManager.default.fileExists(atPath: tree.path("out.zip")))
    }

    @Test("an encrypted job with a blank passphrase writes nothing")
    func blankPassphraseIsRefused() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")
        let report = pack(operation(tree, names: ["alpha.txt"], passphrase: ""))
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
        let report = pack(
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
        let report = pack(
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

    @Test("canceling leaves no archive behind at all")
    func cancellationLeavesNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        for index in 0..<12 {
            try tree.writeFile("file-\(index).bin", bytes: 400_000)
        }
        let names = (0..<12).map { "file-\($0).bin" }

        let canceled = Locked(false)
        let report = pack(
            operation(tree, names: names),
            onProgress: { progress in
                if progress.completedBytes > 0 { canceled.withValue { $0 = true } }
            },
            isCancelled: { canceled.withValue { $0 } }
        )
        #expect(report.wasCancelled)
        #expect(report.pack == nil)
        // Not a truncated archive, not a temporary sibling — nothing. A plausible-looking zip that
        // opens and is missing most of its contents is the failure this is built to avoid.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tree.root.path)
        #expect(leftovers.allSatisfy { $0.hasPrefix("file-") })
    }
}

/// A pack whose destination is on a server (PLAN.md §M24 Slice 6).
///
/// Its own suite rather than a section of `PackRunner`'s, which sits at SwiftLint's
/// `type_body_length` — and the split reads: everything above is about what reaches the *archive*,
/// everything here about what reaches the *server*.
@Suite("PackRunner ▸ a destination on a server")
struct PackRunnerRemoteDestinationTests {
    private func operation(_ tree: TempTree, names: [String], archive: VFSPath) -> FileOperation {
        FileOperation(
            kind: .pack(
                PackJob(
                    sources: PackSource.all(inDirectory: tree.root.path, names: names),
                    archive: archive,
                    encryption: .aes256,
                    passphrase: ArchivePassphrase("correct horse battery staple")
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

    @Test("an archive bound for a server is built here and transferred, leaving no temp behind")
    func remoteDestinationIsUploaded() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        let store = FakeRemoteStore([:])
        let destination = store.path("/backups/out.zip")
        let report = PackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: destination),
            using: store
        )

        #expect(report.succeeded)
        let summary = try summary(report)
        // The summary names where the user asked for it, not where it was built — that path is what
        // the window re-lists and puts the cursor on.
        #expect(summary.archive == destination)
        let uploaded = try #require(store.data(at: "/backups/out.zip"))
        #expect(uploaded.count == summary.byteSize)
        // Really an archive, not an empty file that landed under the right name: a zip's local file
        // header is the one thing a wrong answer here could not produce.
        #expect(uploaded.prefix(2) == Data("PK".utf8))
        // Nothing is left in the temp root, which is the half a user never looks at and would never
        // report — a cancelled or finished pack must not leave somebody's whole archive there.
        #expect(!FileManager.default.fileExists(atPath: tree.path("out.zip")))
        #expect(try stagedArchives(named: "out.zip").isEmpty)
    }

    @Test("a refused upload reports the backend's own reason, not the pack vocabulary")
    func refusedUploadKeepsTheServersReason() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.txt", contents: "alpha")

        let store = FakeRemoteStore([:], refusingUploadsTo: ["/readonly/out.zip"])
        let destination = store.path("/readonly/out.zip")
        let report = PackRunner.run(
            operation(tree, names: ["alpha.txt"], archive: destination),
            using: store
        )

        // Not `.created` — the archive exists nowhere the user can reach — and not an
        // `EncryptedArchiveError` either: the write worked and the transfer did not, so what the
        // user reads is what the thing that declined actually said.
        #expect(report.pack == nil)
        #expect(!report.wasCancelled)
        let failure = try #require(report.failures.first)
        #expect(failure.path == destination)
        #expect(failure.error == .permissionDenied(destination))
        #expect(try stagedArchives(named: "out.zip").isEmpty)
    }

    @Test("the bar keeps moving through the upload instead of parking full")
    func uploadExtendsTheBarRatherThanFillingIt() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("alpha.bin", bytes: 200_000)

        let store = FakeRemoteStore([:])
        let updates = Locked<[OperationProgress]>([])
        let report = PackRunner.run(
            operation(tree, names: ["alpha.bin"], archive: store.path("/out.zip")),
            using: store,
            onProgress: { progress in updates.withValue { $0.append(progress) } }
        )
        #expect(report.succeeded)

        let seen = updates.withValue { $0 }
        let last = try #require(seen.last)
        let packed = try #require(seen.first).totalBytes
        // The total grows exactly once, when the transfer starts, and the final report agrees with
        // the last thing drawn — a report short of it walks the aggregate bar backwards at the very
        // end (docs/NOTES.md ▸ AppKit, on a view that keeps the last value it was drawn with).
        #expect(last.totalBytes > packed)
        #expect(last.completedBytes == last.totalBytes)
        #expect(report.completedBytes == last.totalBytes)
        // Monotonic throughout: never a reset to zero, never a step back.
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
    }

    /// Anything called `name` left lying in the temp root — the staging sweep's own observable.
    private func stagedArchives(named name: String) throws -> [String] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let holders = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return holders.filter { holder in
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(holder).appendingPathComponent(name).path
            )
        }
    }
}

/// A tiny mutex for values the progress callback writes from the writer's own thread.

/// A value two threads may touch, for a test that collects what a `@Sendable` progress closure
/// reported.
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
