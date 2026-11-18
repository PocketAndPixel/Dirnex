import Foundation
import Testing

@testable import DirnexCore

/// ⌥F5 with a path for a name (2026-11-18): which archive the typed text asks for, and the folders
/// on the way made before the write and taken back when it lands no archive. Both runners are driven,
/// because each makes the folders itself; the plain one through a fake `bsdtar`, the encrypted one
/// through the real libarchive writer with no cipher.
@Suite("Packing into a typed path")
struct PackFoldersTests {
    // MARK: - The name

    private static func components(_ typed: String, _ format: ArchivePacking.Format = .zip) -> [
        String
    ]? {
        try? ArchivePacking.archiveName(typed: typed, format: format).components
    }

    private static func problem(_ typed: String) -> NestedName.Problem? {
        do {
            _ = try ArchivePacking.archiveName(typed: typed, format: .zip)
            return nil
        } catch {
            return error
        }
    }

    @Test("a plain name is the archive it always was")
    func plainName() {
        #expect(Self.components("docs") == ["docs.zip"])
        #expect(Self.components("docs.zip") == ["docs.zip"])
        #expect(Self.components("  docs  ") == ["docs.zip"])
        #expect(Self.components("") == ["Archive.zip"])
        #expect(Self.components("   ") == ["Archive.zip"])
        #expect(Self.components("docs", .tarGz) == ["docs.tar.gz"])
    }

    @Test("a path names its folders, and the suffix goes on the last name only")
    func pathName() {
        #expect(Self.components("backups/2026/photos") == ["backups", "2026", "photos.zip"])
        #expect(Self.components("backups.zip/photos") == ["backups.zip", "photos.zip"])
        #expect(Self.components("backups//photos.zip") == ["backups", "photos.zip"])
    }

    /// Checked before the suffix goes on: `backups/` would otherwise be a hidden `backups/.zip`.
    @Test("a path that names no archive is refused with its reason")
    func refusals() {
        #expect(Self.problem("backups/") == .endsInSlash)
        #expect(Self.problem("/backups/photos") == .startsAtRoot)
        #expect(Self.problem("backups/../photos") == .reserved(".."))
        #expect(Self.problem("..") == .reserved(".."))
    }

    // MARK: - The folders on the way

    @Test("the folders between the destination and the archive are made, outermost first")
    func makesTheFoldersOnTheWay() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        let made = try NestedCreation.makeFolders(
            above: tree.vfsPath("backups/2026/photos.zip"), below: tree.vfsPath(),
            using: LocalBackend()
        )

        #expect(made == [tree.vfsPath("backups"), tree.vfsPath("backups/2026")])
        // Only the folders: the archive is its writer's to make.
        #expect(!FileManager.default.fileExists(atPath: tree.path("backups/2026/photos.zip")))
    }

    @Test("an archive directly in the destination, or outside it, makes nothing")
    func makesNothingOutsideThePath() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let backend = LocalBackend()

        #expect(try NestedCreation.makeFolders(
            above: tree.vfsPath("photos.zip"), below: tree.vfsPath(), using: backend
        ).isEmpty)
        #expect(try NestedCreation.makeFolders(
            above: .local("/elsewhere/deep/photos.zip"), below: tree.vfsPath(), using: backend
        ).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.root.path).isEmpty)
    }

    // MARK: - The plain pack

    private static func created(_ report: OperationReport) -> Bool {
        if case .created? = report.pack { return true }
        return false
    }

    private struct FakeWriter: PlainPackWriting {
        var failure: (any Error)?

        func pack(
            _ request: PlainPackRequest,
            onProgress _: @escaping @Sendable (BsdtarProgressSample) -> Void,
            isCancelled _: @escaping @Sendable () -> Bool
        ) throws {
            if let failure { throw failure }
            FileManager.default.createFile(
                atPath: request.archiveOnDiskPath,
                contents: Data("zip".utf8)
            )
        }
    }

    private static func plainPack(_ tree: TempTree, archive: VFSPath) -> FileOperation {
        FileOperation(
            kind: .plainPack(
                PlainPackJob(
                    sources: PackSource.all(inDirectory: tree.path("src"), names: ["a.txt"]),
                    archive: archive,
                    format: .zip
                )
            ),
            sources: [],
            destinationDirectory: tree.vfsPath("dest")
        )
    }

    private static func tree() throws -> TempTree {
        let tree = try TempTree()
        try tree.makeDir("src")
        try tree.writeFile("src/a.txt", contents: "alpha")
        try tree.makeDir("dest")
        return tree
    }

    @Test("a plain pack lands below the folders it made")
    func plainPackMakesTheFolders() throws {
        let tree = try Self.tree()
        defer { tree.cleanup() }
        let archive = tree.vfsPath("dest/backups/2026/photos.zip")

        let report = PlainPackRunner.run(
            Self.plainPack(tree, archive: archive), using: LocalBackend(), writer: FakeWriter()
        )

        guard case let .created(summary)? = report.pack else {
            Issue.record("expected a pack summary, got \(String(describing: report.pack))")
            return
        }
        #expect(summary.archive == archive)
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    /// The promise both runners make, that a pack which does not finish leaves nothing at the
    /// destination, has to cover the folders now too, or a stopped pack would leave `backups` behind
    /// with nothing in it and no undo to remove it.
    @Test("a stopped or failed plain pack takes back the folders it made, and only those")
    func plainPackTakesBack() throws {
        for failure: any Error in [CancellationError(), VFSError.io(path: .local("/x"), code: 5)] {
            let tree = try Self.tree()
            defer { tree.cleanup() }
            try tree.makeDir("dest/kept")

            let report = PlainPackRunner.run(
                Self.plainPack(tree, archive: tree.vfsPath("dest/kept/new/photos.zip")),
                using: LocalBackend(),
                writer: FakeWriter(failure: failure)
            )

            #expect(!Self.created(report))
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: tree.path("dest")) == ["kept"]
            )
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: tree.path("dest/kept")).isEmpty
            )
        }
    }

    /// The failure names the file in the way, which is what lets the app say which name is wrong.
    @Test("a file on the way fails the pack naming it, before anything is written")
    func plainPackRefusesAFileOnTheWay() throws {
        let tree = try Self.tree()
        defer { tree.cleanup() }
        try tree.writeFile("dest/backups", contents: "not a folder")

        let report = PlainPackRunner.run(
            Self.plainPack(tree, archive: tree.vfsPath("dest/backups/photos.zip")),
            using: LocalBackend(),
            writer: FakeWriter(failure: VFSError.io(path: .local("/never"), code: 1))
        )

        #expect(report.failures.map(\.error) == [.notADirectory(tree.vfsPath("dest/backups"))])
        #expect(report.failures.map(\.path) == [tree.vfsPath("dest/backups/photos.zip")])
    }

    /// Through the queue the app uses, which is also what tells the window which folder the pack was
    /// aimed at: a typed path puts the archive below folders no pane shows, so the snapshot has to
    /// carry the destination for the finished pack to find its pane.
    @Test("through the queue, the pack lands and the snapshot names where it was aimed")
    func throughTheQueue() async throws {
        let tree = try Self.tree()
        defer { tree.cleanup() }
        let archive = tree.vfsPath("dest/backups/photos.zip")

        let queue = FileOperationQueue(backend: LocalBackend(), plainPackWriter: FakeWriter())
        let id = await queue.enqueue(Self.plainPack(tree, archive: archive))
        await queue.waitUntilIdle()

        let job = try #require(await queue.snapshot().jobs.first { $0.id == id })
        #expect(job.destinationDirectory == tree.vfsPath("dest"))
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    // MARK: - The encrypted pack's runner

    private static func encryptedPack(_ tree: TempTree, archive: VFSPath, names: [String]) -> FileOperation {
        FileOperation(
            kind: .pack(
                PackJob(
                    sources: PackSource.all(inDirectory: tree.path("src"), names: names),
                    archive: archive,
                    encryption: .none,
                    passphrase: nil
                )
            ),
            sources: [],
            destinationDirectory: tree.vfsPath("dest")
        )
    }

    @Test("the libarchive pack lands below the folders it made")
    func encryptedPackMakesTheFolders() throws {
        let tree = try Self.tree()
        defer { tree.cleanup() }
        let archive = tree.vfsPath("dest/backups/photos.zip")

        let report = PackRunner.run(
            Self.encryptedPack(tree, archive: archive, names: ["a.txt"]), using: LocalBackend()
        )

        guard case .created? = report.pack else {
            Issue.record("expected a pack summary, got \(String(describing: report.pack))")
            return
        }
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test("a libarchive pack that fails takes back the folders it made")
    func encryptedPackTakesBack() throws {
        let tree = try Self.tree()
        defer { tree.cleanup() }

        // A source that is not there fails the walk, after the folders were made.
        let report = PackRunner.run(
            Self.encryptedPack(
                tree,
                archive: tree.vfsPath("dest/backups/photos.zip"),
                names: ["gone.txt"]
            ),
            using: LocalBackend()
        )

        #expect(!Self.created(report))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.path("dest")).isEmpty)
    }
}
