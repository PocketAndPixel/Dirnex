import Foundation
import Testing

@testable import DirnexCore

/// Exercises the M2 byte-copy primitives on `LocalBackend` — the clone fast path, the
/// chunked file copy with progress and cancellation, symlink duplication, and metadata
/// preservation — against a throwaway on-disk tree (PLAN.md §2 "if it touches bytes, it
/// lives in DirnexCore and has tests").
@Suite("LocalBackend copy primitives")
struct LocalBackendCopyTests {
    let backend = LocalBackend()

    // MARK: - cloneItem

    @Test("clones a file same-volume, preserving contents")
    func clonesFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("src.txt", contents: "clone me")

        let cloned = try backend.cloneItem(at: tree.vfsPath("src.txt"), to: tree.vfsPath("dst.txt"))
        #expect(cloned) // temp dir is APFS, so a same-volume clone succeeds
        #expect(try String(contentsOfFile: tree.path("dst.txt"), encoding: .utf8) == "clone me")
    }

    @Test("clones a whole directory subtree in one shot")
    func clonesTree() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid")
        try tree.writeFile("top/a.txt", contents: "a")
        try tree.writeFile("top/mid/b.txt", contents: "b")

        #expect(try backend.cloneItem(at: tree.vfsPath("top"), to: tree.vfsPath("copy")))
        #expect(try String(contentsOfFile: tree.path("copy/mid/b.txt"), encoding: .utf8) == "b")
    }

    @Test("cloning onto an existing destination throws alreadyExists")
    func cloneOntoExistingThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("src.txt", contents: "x")
        try tree.writeFile("dst.txt", contents: "y")

        let dst = tree.vfsPath("dst.txt")
        #expect(throws: VFSError.alreadyExists(dst)) {
            try backend.cloneItem(at: tree.vfsPath("src.txt"), to: dst)
        }
    }

    // MARK: - copyFile (chunked fallback)

    @Test("copies a multi-chunk file, reporting cumulative progress")
    func copyFileReportsProgress() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let size = (1 << 20) * 3 + 512 // 3 chunks + a partial
        try tree.writeFile("big.bin", bytes: size)

        var reported: Int64 = 0
        try backend.copyFile(
            at: tree.vfsPath("big.bin"),
            to: tree.vfsPath("big-copy.bin"),
            progress: { reported += $0 },
            isCancelled: { false }
        )

        #expect(reported == Int64(size))
        #expect(try backend.stat(at: tree.vfsPath("big-copy.bin")).byteSize == Int64(size))
    }

    @Test("copyFile preserves POSIX permissions")
    func copyFilePreservesPermissions() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("secret.txt", contents: "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        try backend.copyFile(
            at: tree.vfsPath("secret.txt"),
            to: tree.vfsPath("secret-copy.txt"),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(try backend.stat(at: tree.vfsPath("secret-copy.txt")).permissions == 0o600)
    }

    @Test("copyFile cancelled mid-stream throws and leaves no partial file")
    func copyFileCancelCleansUp() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("big.bin", bytes: (1 << 20) * 4)

        var polls = 0
        let dst = tree.vfsPath("partial.bin")
        #expect(throws: CancellationError.self) {
            try backend.copyFile(
                at: tree.vfsPath("big.bin"),
                to: dst,
                progress: { _ in },
                isCancelled: { polls += 1; return polls > 1 } // cancel after the first chunk
            )
        }
        #expect(throws: VFSError.notFound(dst)) { try backend.stat(at: dst) }
    }

    // MARK: - createSymbolicLink

    @Test("recreates a symbolic link pointing at the same target")
    func createsSymlink() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        try backend.createSymbolicLink(at: tree.vfsPath("link"), withDestination: "/some/target")
        let entry = try backend.stat(at: tree.vfsPath("link"))
        #expect(entry.kind == .symlink)
        #expect(entry.symlinkDestination == "/some/target")
    }
}
