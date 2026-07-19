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
            try DirectorySizer.size(of: tree.vfsPath(), using: backend) { true }
        }
    }

    @Test("sizing a nonexistent path totals zero rather than throwing")
    func missingPathIsZero() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        // The top-level listing fails and is skipped, leaving an empty total.
        #expect(try DirectorySizer.size(of: tree.vfsPath("nope"), using: backend) == 0)
    }
}
