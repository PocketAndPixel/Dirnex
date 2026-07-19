import Foundation
import Testing

@testable import DirnexCore

/// The copy/move engine's behaviour under the failure modes PLAN.md §5 mandates for every
/// operation but that the happy-path/conflict suites don't reach: **permission denied**,
/// **disk full** (`ENOSPC`), and the **source mutated during the op**. The theme is
/// safety — a failed item is collected and the operation carries on, a failed copy never
/// deletes the source it was moving or the destination it was overwriting, and a
/// half-written file is never left behind.
///
/// Real out-of-space and (mostly) permission conditions aren't hermetic, so they're
/// injected through a `FaultBackend` test double — the same approach `CrossVolumeBackend`
/// takes for `EXDEV` rather than mounting two real volumes. One test exercises a real
/// unreadable source so the POSIX errno → `VFSError` mapping is covered end to end.
@Suite("CopyEngine failures")
struct CopyEngineFailureTests {
    private let fs = LocalBackend()

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try fs.stat(at: tree.vfsPath(relative))
    }

    private func contents(_ tree: TempTree, _ relative: String) throws -> String {
        try String(contentsOfFile: tree.path(relative), encoding: .utf8)
    }

    private func exists(_ tree: TempTree, _ relative: String) -> Bool {
        (try? fs.stat(at: tree.vfsPath(relative))) != nil
    }

    // MARK: - Permission denied

    @Test("a permission failure on one source is collected; the others still copy")
    func permissionDeniedIsCollectedOthersProceed() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("locked.txt", contents: "secret")
        try tree.writeFile("ok.txt", contents: "fine")
        try tree.makeDir("dest")

        let backend = FaultBackend(
            blocksClone: true,
            copyFileFault: { $0.lastComponent == "locked.txt" ? .permissionDenied($0) : nil }
        )
        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "locked.txt"), try stat(tree, "ok.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend)

        #expect(!report.succeeded)
        #expect(!report.wasCancelled)
        #expect(report.completedItems == 1)
        #expect(report.failures.first?.error == .permissionDenied(tree.vfsPath("locked.txt")))
        #expect(try contents(tree, "dest/ok.txt") == "fine")
        #expect(!exists(tree, "dest/locked.txt")) // no partial from the denied source
    }

    @Test("a real unreadable source maps to permissionDenied through copyFile")
    func realUnreadableSourceMapsToPermissionDenied() throws {
        guard getuid() != 0 else { return } // root bypasses the mode bits — nothing to test
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("secret.txt", contents: "x")
        try tree.makeDir("dest")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: tree.path("secret.txt")
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: tree.path("secret.txt")
            )
        }

        // Force the chunked path so the copy actually opens the file for reading (EACCES).
        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "secret.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: FaultBackend(blocksClone: true))

        #expect(!report.succeeded)
        #expect(report.failures.first?.error == .permissionDenied(tree.vfsPath("secret.txt")))
        #expect(!exists(tree, "dest/secret.txt"))
    }

    // MARK: - Disk full (ENOSPC)

    @Test("a disk-full copy during a cross-volume move keeps the source")
    func diskFullDuringMoveKeepsSource() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.bin", contents: "payload")
        try tree.makeDir("dest")

        // Cross-volume so the move falls back to copy-then-delete, and the copy runs out
        // of space — the source must survive, since it's only removed after a good copy.
        let backend = FaultBackend(
            blocksClone: true,
            movesCrossVolume: true,
            copyFileFault: { .io(path: $0, code: ENOSPC) }
        )
        let op = FileOperation(
            kind: .move,
            sources: [try stat(tree, "a.bin")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend)

        #expect(!report.succeeded)
        #expect(report.completedItems == 0)
        #expect(report.failures.first?.error == .io(path: tree.vfsPath("a.bin"), code: ENOSPC))
        #expect(try contents(tree, "a.bin") == "payload") // source untouched
        #expect(!exists(tree, "dest/a.bin"))
    }

    @Test("a disk-full overwrite keeps the existing destination and leaves no temp file")
    func diskFullDuringOverwriteKeepsExisting() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "new")
        try tree.makeDir("dest")
        try tree.writeFile("dest/a.txt", contents: "original")

        // Overwrite writes to a temp sibling first; if that runs out of space the engine
        // must never remove the existing file — the whole point of the atomic swap.
        let backend = FaultBackend(
            blocksClone: true,
            copyFileFault: { .io(path: $0, code: ENOSPC) }
        )
        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend, conflictPolicy: .overwrite)

        #expect(!report.succeeded)
        #expect(try contents(tree, "dest/a.txt") == "original") // existing preserved
        #expect(try fs.listDirectory(at: tree.vfsPath("dest")).map(\.name) == ["a.txt"])
    }

    @Test("cancelling mid-file unlinks the half-written destination")
    func midFileCancelUnlinksPartial() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("big.bin", bytes: 4 << 20) // 4 MiB → several 1 MiB chunks
        try tree.makeDir("dest")

        // Cancel after the first chunk is written, so a partial file genuinely exists and
        // the real `LocalBackend.copyFile` cleanup path (close + unlink) is exercised.
        let probe = CallCounter()
        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "big.bin")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(
            op,
            using: FaultBackend(blocksClone: true),
            isCancelled: { probe.next() >= 4 }
        )

        #expect(report.wasCancelled)
        #expect(!exists(tree, "dest/big.bin")) // partial cleaned up, not left behind
    }

    // MARK: - Source mutated during the operation

    @Test("a source that vanished after selection is recorded as notFound, not fatal")
    func vanishedSourceIsRecordedNotFatal() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "A")
        try tree.writeFile("b.txt", contents: "B")
        try tree.makeDir("dest")

        let sources = [try stat(tree, "a.txt"), try stat(tree, "b.txt")]
        try fs.removeItem(at: tree.vfsPath("a.txt")) // gone between selection and copy

        let op = FileOperation(
            kind: .copy,
            sources: sources,
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: fs)

        #expect(!report.succeeded)
        #expect(!report.wasCancelled)
        #expect(report.completedItems == 1)
        // The vanished source surfaces as a notFound failure rather than crashing the op.
        // (On the clone fast path `LocalBackend.cloneItem` attributes the clonefile errno to
        // the destination, so we assert the case, not the incidental path.)
        let error = try #require(report.failures.first?.error)
        if case .notFound = error {} else {
            Issue.record("expected a .notFound failure, got \(error)")
        }
        #expect(try contents(tree, "dest/b.txt") == "B")
        #expect(!exists(tree, "dest/a.txt"))
    }

    @Test("a source appended to mid-copy is copied in full, not truncated to its scanned size")
    func sourceAppendedMidCopyIsCopiedInFull() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("m.txt", contents: "ORIG")
        try tree.makeDir("dest")

        // Grow the source just as the copy begins: the engine streams to EOF, so the
        // destination reflects the live bytes rather than the pre-scanned length.
        let backend = FaultBackend(blocksClone: true, beforeCopyFile: { path in
            guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path.path))
            else { return }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("-EXTRA".utf8))
            try? handle.close()
        })
        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "m.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend)

        #expect(report.succeeded)
        #expect(try contents(tree, "dest/m.txt") == "ORIG-EXTRA")
    }
}

// MARK: - Test doubles

/// Counts calls so a test can flip a decision (e.g. cancel) after a fixed number of polls.
/// `CopyEngine.run` is synchronous on one thread, so no real concurrency touches `count`.
private final class CallCounter: @unchecked Sendable {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

/// A `LocalBackend` wrapper that injects copy-time faults, generalizing the pattern of
/// `NoCloneBackend`/`CrossVolumeBackend`: block cloning to force the chunked path, make
/// moves report cross-volume, fail `copyFile` for chosen sources, or run a side effect
/// just before a copy (to mutate the source under the engine). Everything else forwards
/// to a real `LocalBackend`.
private struct FaultBackend: VFSBackend {
    private let inner = LocalBackend()

    /// Report "no clone" so `CopyEngine` takes the chunked recursive-copy fallback.
    var blocksClone = false
    /// Report every rename as `EXDEV`, so a move falls back to copy-then-delete.
    var movesCrossVolume = false
    /// Return an error to fail `copyFile` for a source instead of copying it (`nil` copies).
    var copyFileFault: @Sendable (VFSPath) -> VFSError? = { _ in nil }
    /// Side effect run at the top of `copyFile`, before forwarding — a seam for mutating
    /// the source mid-operation.
    var beforeCopyFile: @Sendable (VFSPath) -> Void = { _ in }

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        if movesCrossVolume { throw VFSError.io(path: source, code: EXDEV) }
        try inner.moveItem(at: source, to: destination)
    }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool {
        if blocksClone { return false }
        return try inner.cloneItem(at: source, to: destination)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if let fault = copyFileFault(source) { throw fault }
        beforeCopyFile(source)
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }

    func volumeIdentifier(for path: VFSPath) -> String? { inner.volumeIdentifier(for: path) }
}
