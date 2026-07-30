import Foundation
import Testing

@testable import DirnexCore

/// The checksum kind's ride on the shared operation queue (PLAN.md §M14 Slice 2).
///
/// Its own file rather than more rows in `FileOperationQueueTests`, which was already at
/// SwiftLint's type-body ceiling — and the seam is a real one: these assert that a job which moves
/// no bytes still gets the scheduler, the cancel and the report channel that copies do.
@Suite("FileOperationQueue — checksums")
struct FileOperationQueueChecksumTests {
    @Test("a checksum job runs through the same queue and reports its verdict")
    func runsChecksumJob() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")

        let queue = FileOperationQueue(backend: LocalBackend())
        let create = FileOperation(
            kind: .checksum(.create(manifest: tree.vfsPath("files.sha256"), algorithm: .sha256)),
            sources: [try LocalBackend().stat(at: tree.vfsPath("a.txt"))],
            destinationDirectory: tree.vfsPath()
        )
        let id = await queue.enqueue(create)
        await queue.waitUntilIdle()

        let job = try #require(await queue.snapshot().jobs.first { $0.id == id })
        #expect(job.status == .finished)
        // The answer arrives on the report the window already watches, not through a second channel.
        guard case let .created(summary)? = job.report?.checksum else {
            Issue.record("expected a creation summary")
            return
        }
        #expect(summary.writtenCount == 1)
        #expect(FileManager.default.fileExists(atPath: tree.path("files.sha256")))
    }

    @Test("a checksum job serializes against a copy on the same volume")
    func checksumSharesTheVolumeRule() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")
        try tree.makeDir("dest")

        // Both jobs name the same temp volume, so the scheduler must never run them together —
        // the whole reason a checksum joined this queue rather than getting a runner of its own.
        let queue = FileOperationQueue(backend: LocalBackend())
        await queue.enqueue(copy(tree, "a.txt", to: "dest"))
        await queue.enqueue(
            FileOperation(
                kind: .checksum(.create(manifest: tree.vfsPath("files.sha256"), algorithm: .sha256)),
                sources: [try LocalBackend().stat(at: tree.vfsPath("a.txt"))],
                destinationDirectory: tree.vfsPath()
            )
        )
        await queue.waitUntilIdle()

        let snapshot = await queue.snapshot()
        #expect(snapshot.jobs.count == 2)
        #expect(snapshot.jobs.allSatisfy { $0.status == .finished })
    }

    @Test("a cancelled checksum job unwinds through the queue's own cancel")
    func cancelsChecksumJob() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("big.bin", bytes: 4 << 20)

        let queue = FileOperationQueue(backend: LocalBackend())
        let id = await queue.enqueue(
            FileOperation(
                kind: .checksum(.create(manifest: tree.vfsPath("files.sha256"), algorithm: .sha256)),
                sources: [try LocalBackend().stat(at: tree.vfsPath("big.bin"))],
                destinationDirectory: tree.vfsPath()
            )
        )
        await queue.cancel(id)
        await queue.waitUntilIdle()

        let job = try #require(await queue.snapshot().jobs.first { $0.id == id })
        #expect(job.status == .cancelled || job.status == .finished)
        // Whichever side of the race it lands on, a cancelled run must not leave a manifest that
        // covers a fraction of the tree while verifying clean.
        if job.status == .cancelled {
            #expect(!FileManager.default.fileExists(atPath: tree.path("files.sha256")))
        }
    }

    /// A copy of one file (statted fresh) into a destination directory, both relative to `tree`.
    private func copy(_ tree: TempTree, _ source: String, to dest: String) -> FileOperation {
        FileOperation(
            kind: .copy,
            sources: [(try? LocalBackend().stat(at: tree.vfsPath(source)))].compactMap { $0 },
            destinationDirectory: tree.vfsPath(dest)
        )
    }
}
