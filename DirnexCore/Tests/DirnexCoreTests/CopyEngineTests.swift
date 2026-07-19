import Foundation
import Testing

@testable import DirnexCore

/// End-to-end tests for the copy/move operation engine (PLAN.md §M2): the clone-backed
/// happy paths, cancellation, progress accounting, and — via test backends that suppress
/// cloning or force a cross-volume error — the chunked recursive fallback and the move's
/// copy-then-delete path. The conflict-policy matrix lives in `CopyEngineConflictTests`.
@Suite("CopyEngine")
struct CopyEngineTests {
    let backend = LocalBackend()

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try backend.stat(at: tree.vfsPath(relative))
    }

    private func contents(_ tree: TempTree, _ relative: String) throws -> String {
        try String(contentsOfFile: tree.path(relative), encoding: .utf8)
    }

    // MARK: - Copy

    @Test("copies a file, leaving the original in place")
    func copiesFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "hello")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend)

        #expect(report.succeeded)
        #expect(report.completedItems == 1)
        #expect(try contents(tree, "dest/a.txt") == "hello")
        #expect(try contents(tree, "a.txt") == "hello") // original untouched
    }

    @Test("copies a directory subtree")
    func copiesTree() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid")
        try tree.writeFile("top/a.txt", contents: "a")
        try tree.writeFile("top/mid/b.txt", contents: "b")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "top")],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)
        #expect(try contents(tree, "dest/top/mid/b.txt") == "b")
    }

    // MARK: - Move

    @Test("moves a file: original gone, destination present")
    func movesFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "x")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .move,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)

        #expect(try contents(tree, "dest/a.txt") == "x")
        #expect(throws: VFSError.notFound(tree.vfsPath("a.txt"))) { try stat(tree, "a.txt") }
    }

    @Test("moves a directory subtree")
    func movesTree() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid")
        try tree.writeFile("top/mid/b.txt", contents: "b")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .move,
            sources: [try stat(tree, "top")],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)
        #expect(try contents(tree, "dest/top/mid/b.txt") == "b")
        #expect(throws: VFSError.notFound(tree.vfsPath("top"))) { try stat(tree, "top") }
    }

    @Test("a cross-volume move copies the bytes then deletes the source")
    func movesAcrossVolumes() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "ferry me")
        try tree.makeDir("dest")

        let backend = CrossVolumeBackend()
        let op = FileOperation(
            kind: .move,
            sources: [try backend.stat(at: tree.vfsPath("a.txt"))],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)

        #expect(try contents(tree, "dest/a.txt") == "ferry me")
        #expect(throws: VFSError.notFound(tree.vfsPath("a.txt"))) { try backend.stat(
            at: tree.vfsPath("a.txt")
        ) }
    }

    // MARK: - Cancellation & progress

    @Test("cancelling before any work leaves a cancelled report and copies nothing")
    func cancelledCopiesNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "x")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend, isCancelled: { true })

        #expect(report.wasCancelled)
        #expect(report.completedItems == 0)
        #expect(throws: VFSError.notFound(tree.vfsPath("dest/a.txt"))) { try stat(tree, "dest/a.txt") }
    }

    @Test("progress runs from zero to the full byte total")
    func reportsProgress() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.bin", bytes: 4096)
        try tree.writeFile("b.bin", bytes: 2048)
        try tree.makeDir("dest")

        let sources = [try stat(tree, "a.bin"), try stat(tree, "b.bin")]
        let op = FileOperation(
            kind: .copy,
            sources: sources,
            destinationDirectory: tree.vfsPath("dest")
        )

        final class Box: @unchecked Sendable { var last: OperationProgress? }
        let box = Box()
        let report = CopyEngine.run(op, using: backend, onProgress: { box.last = $0 })

        #expect(report.completedBytes == 6144)
        let final = try #require(box.last)
        #expect(final.totalBytes == 6144)
        #expect(final.completedBytes == 6144)
        #expect(final.completedItems == 2)
    }

    // MARK: - Chunked fallback (no-clone backend)

    @Test("without cloning, a subtree copies by hand identically")
    func manualFallbackCopiesTree() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid")
        try tree.writeFile("top/a.txt", contents: "a")
        try tree.writeFile("top/mid/b.txt", contents: "b")
        try tree.makeDir("dest")

        let backend = NoCloneBackend()
        let op = FileOperation(
            kind: .copy,
            sources: [try backend.stat(at: tree.vfsPath("top"))],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)
        #expect(try contents(tree, "dest/top/a.txt") == "a")
        #expect(try contents(tree, "dest/top/mid/b.txt") == "b")
    }

    @Test("without cloning, a nested symlink is duplicated as a symlink")
    func manualFallbackPreservesSymlink() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top")
        try tree.symlink("top/link", to: "/some/target")
        try tree.makeDir("dest")

        let backend = NoCloneBackend()
        let op = FileOperation(
            kind: .copy,
            sources: [try backend.stat(at: tree.vfsPath("top"))],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)

        let link = try backend.stat(at: tree.vfsPath("dest/top/link"))
        #expect(link.kind == .symlink)
        #expect(link.symlinkDestination == "/some/target")
    }

    // MARK: - Cross-backend copy (upload) never clones

    /// Regression: a copy whose source and destination live on *different* backends (an upload —
    /// local file → remote pane) must not attempt a copy-on-write clone. A clone is a
    /// single-filesystem primitive, so routing one across backends made `LocalBackend` read the
    /// remote destination path as a *local* one — a subfolder like `/test/x` then failed with
    /// `clonefile`'s ENOENT, surfaced to the user as "The item no longer exists". The engine must
    /// skip the clone on backend mismatch and transfer by hand instead.
    @Test("a cross-backend copy skips cloning and transfers by hand")
    func crossBackendCopyDoesNotClone() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "payload")

        let backend = CrossBackendUploadBackend()
        // The destination is a subfolder on a *different* backend — the shape that misrouted the clone.
        let destDir = VFSPath(backend: CrossBackendUploadBackend.remoteID, path: "/test")
        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: destDir
        )

        let report = CopyEngine.run(op, using: backend)

        #expect(report.succeeded)
        #expect(backend.cloneCalls == 0) // a clone can't cross backends — it must never be attempted
        let landed = try backend.stat(at: destDir.appending("a.txt"))
        #expect(landed.byteSize == Int64("payload".utf8.count))
    }
}

// MARK: - Test backends

/// Wraps `LocalBackend` but always reports "no clone", forcing the engine down its
/// chunked recursive-copy fallback so that path is covered without needing two volumes.
private struct NoCloneBackend: VFSBackend {
    private let inner = LocalBackend()
    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func moveItem(at source: VFSPath, to destination: VFSPath) throws { try inner.moveItem(
        at: source,
        to: destination
    ) }
    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool { false }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }
}

/// Wraps `LocalBackend` but reports every rename as a cross-device error, exercising the
/// move engine's copy-then-delete fallback path.
private struct CrossVolumeBackend: VFSBackend {
    private let inner = LocalBackend()
    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        throw VFSError.io(path: source, code: EXDEV) // pretend every move crosses a volume
    }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool { false }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }
}

/// A two-namespace routing fake, modelling the app's `CompositeBackend` for an upload: real on-disk
/// files under `.local`, plus an in-memory "remote" backend under a distinct id that advertises no
/// clone (like SFTP). `cloneItem` traps a cross-backend call — a clone can only be same-backend, so
/// the engine must never route one here across backends; if it does (the pre-fix bug), the trap
/// throws `.notFound`, reproducing the misrouted `clonefile`'s failure.
private final class CrossBackendUploadBackend: VFSBackend, @unchecked Sendable {
    static let remoteID = VFSBackendID("test-remote")
    private let localInner = LocalBackend()
    private let lock = NSLock()
    private var remoteStore: [String: Data] = [:]
    private(set) var cloneCalls = 0

    var id: VFSBackendID { .local }
    var capabilities: VFSCapabilities { localInner.capabilities }

    /// Local paths report the full local set (crucially `.clone`, so the *source*-only check the bug
    /// relied on would pass); the remote backend is writable but clone-less, like a connected SFTP.
    func capabilities(for path: VFSPath) -> VFSCapabilities {
        path.backend == .local ? localInner.capabilities : [.read, .write, .rename]
    }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool {
        lock.lock(); cloneCalls += 1; lock.unlock()
        guard source.backend == destination.backend else {
            // What the misroute did: `LocalBackend` read the remote path as a local one and found
            // nothing there (`clonefile` → ENOENT → `.notFound`).
            throw VFSError.notFound(destination)
        }
        return try localInner.cloneItem(at: source, to: destination)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: source.path))
        lock.lock(); remoteStore[destination.path] = data; lock.unlock()
        progress(Int64(data.count))
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        if path.backend == .local { return try localInner.stat(at: path) }
        lock.lock(); let data = remoteStore[path.path]; lock.unlock()
        guard let data else { throw VFSError.notFound(path) }
        return FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .file,
            byteSize: Int64(data.count),
            modificationDate: .init(),
            creationDate: .init(),
            isHidden: false,
            permissions: 0o644,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil
        )
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try localInner.listDirectory(
        at: path
    ) }
}
