import Foundation
import Testing

@testable import DirnexCore

@Suite("DirectorySizer")
struct DirectorySizerTests {
    let backend = LocalBackend()

    @Test("totals the files in a flat directory")
    func flat() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.bin", bytes: 100)
        try tree.writeFile("b.bin", bytes: 200)

        #expect(try DirectorySizer.size(of: tree.vfsPath(), using: backend) == 300)
    }

    @Test("recurses through nested subdirectories")
    func nested() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("top.bin", bytes: 10)
        try tree.makeDir("sub/deep")
        try tree.writeFile("sub/mid.bin", bytes: 20)
        try tree.writeFile("sub/deep/leaf.bin", bytes: 40)

        #expect(try DirectorySizer.size(of: tree.vfsPath(), using: backend) == 70)
    }

    @Test("an empty directory totals zero")
    func empty() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("hollow")

        #expect(try DirectorySizer.size(of: tree.vfsPath("hollow"), using: backend) == 0)
    }

    @Test("counts only content bytes, not the directory inodes themselves")
    func directoriesAddNoWeight() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        // Several empty nested directories and one small file.
        try tree.makeDir("a/b/c/d")
        try tree.writeFile("a/b/c/d/leaf.bin", bytes: 7)

        #expect(try DirectorySizer.size(of: tree.vfsPath(), using: backend) == 7)
    }

    @Test("does not follow symlinks — a cycle terminates and links count as their own size")
    func symlinksNotFollowed() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("real.bin", bytes: 1000)
        try tree.makeDir("dir")
        try tree.writeFile("dir/inner.bin", bytes: 500)
        // A symlink pointing back at the root would loop forever if followed.
        try tree.symlink("dir/loop", to: tree.path(""))

        // Terminates, and counts at least the two real files (plus the tiny link inode).
        let total = try DirectorySizer.size(of: tree.vfsPath(), using: backend)
        #expect(total >= 1500)
    }

    @Test("cancellation aborts the walk with CancellationError")
    func cancels() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.bin", bytes: 1)

        #expect(throws: CancellationError.self) {
            try DirectorySizer.size(of: tree.vfsPath(), using: backend, isCancelled: { true })
        }
    }

    @Test("sizing a nonexistent path totals zero rather than throwing")
    func missingPathIsZero() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        // The top-level listing fails and is skipped, leaving an empty total.
        #expect(try DirectorySizer.size(of: tree.vfsPath("nope"), using: backend) == 0)
    }

    // MARK: - Exclusion (.gitignore-aware sizing)

    @Test("an excluded file contributes nothing")
    func excludedFileIsNotCounted() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("keep.bin", bytes: 100)
        try tree.writeFile("debug.log", bytes: 900)

        let total = try DirectorySizer.size(
            of: tree.vfsPath(),
            using: backend,
            // Labelled rather than trailing, at every call site: `size` now takes two closures, and
            // a bare trailing one binds to `isCancelled`.
            excluding: { $0.lastComponent == "debug.log" }
        )
        #expect(total == 100)
    }

    @Test("an excluded directory is pruned, not walked")
    func excludedDirectoryIsNotWalked() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("keep.bin", bytes: 10)
        try tree.makeDir("build/deep")
        try tree.writeFile("build/deep/a.o", bytes: 5000)

        // Not walking it is the point, not a side effect: walk cost tracks entry count, so pruning
        // `node_modules` is most of what makes the mode fast enough to leave on. A counting backend
        // is the only way to prove the subtree was skipped rather than walked and then discarded.
        let counting = CountingBackend()
        let total = try DirectorySizer.size(
            of: tree.vfsPath(),
            using: counting,
            excluding: { $0.lastComponent == "build" }
        )

        #expect(total == 10)
        #expect(!counting.listed.contains { $0.lastComponent == "build" })
        #expect(!counting.listed.contains { $0.lastComponent == "deep" })
    }

    @Test("the path being sized is never tested against the predicate")
    func topLevelIsNeverExcluded() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("build")
        try tree.writeFile("build/a.o", bytes: 42)

        // Pointing at an ignored folder must produce its real size — otherwise every ignored row in
        // a listing would read as empty, which is a different fact entirely.
        let total = try DirectorySizer.size(
            of: tree.vfsPath("build"),
            using: backend,
            excluding: { $0.lastComponent == "build" }
        )
        #expect(total == 42)
    }

    @Test("excluding nothing matches the unfiltered total")
    func emptyExclusionMatchesDefault() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.bin", bytes: 100)
        try tree.makeDir("sub")
        try tree.writeFile("sub/b.bin", bytes: 200)

        let filtered = try DirectorySizer.size(
            of: tree.vfsPath(),
            using: backend,
            excluding: { _ in false }
        )
        #expect(try filtered == DirectorySizer.size(of: tree.vfsPath(), using: backend))
    }
}

/// `LocalBackend` that records every directory it was asked to list — the only way to tell a pruned
/// subtree from one that was walked and then thrown away, since both produce the same total.
private final class CountingBackend: VFSBackend, @unchecked Sendable {
    private let inner = LocalBackend()
    private let lock = NSLock()
    private var listedPaths: [VFSPath] = []

    var listed: [VFSPath] {
        lock.lock()
        defer { lock.unlock() }
        return listedPaths
    }

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        lock.lock()
        listedPaths.append(path)
        lock.unlock()
        return try inner.listDirectory(at: path)
    }

    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
}
