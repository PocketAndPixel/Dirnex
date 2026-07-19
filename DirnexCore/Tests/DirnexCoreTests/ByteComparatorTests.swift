import Foundation
import Testing

@testable import DirnexCore

@Suite("ByteComparator")
struct ByteComparatorTests {
    @Test("identical files compare equal")
    func identical() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "hello world")
        try tree.writeFile("b", contents: "hello world")

        #expect(try ByteComparator.localFilesEqual(tree.vfsPath("a"), tree.vfsPath("b")))
    }

    @Test("same-size, different-content files compare unequal")
    func sameSizeDifferentBytes() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "aaaa")
        try tree.writeFile("b", contents: "aaba")

        #expect(try !ByteComparator.localFilesEqual(tree.vfsPath("a"), tree.vfsPath("b")))
    }

    @Test("different-size files compare unequal without reading (size short-circuit)")
    func differentSize() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "short")
        try tree.writeFile("b", contents: "a much longer string")

        #expect(try !ByteComparator.localFilesEqual(tree.vfsPath("a"), tree.vfsPath("b")))
    }

    @Test("two empty files compare equal")
    func emptyFiles() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", bytes: 0)
        try tree.writeFile("b", bytes: 0)

        #expect(try ByteComparator.localFilesEqual(tree.vfsPath("a"), tree.vfsPath("b")))
    }

    @Test("a path compared with itself is trivially equal")
    func samePath() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "x")

        #expect(try ByteComparator.localFilesEqual(tree.vfsPath("a"), tree.vfsPath("a")))
    }

    @Test("chunk-boundary difference in a later chunk is caught")
    func multiChunkDifference() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "0123456789")
        try tree.writeFile("b", contents: "0123456780") // differs only in the final byte

        // A tiny chunk forces several reads, so the mismatch is in a non-first chunk.
        let equal = try ByteComparator.localFilesEqual(
            tree.vfsPath("a"),
            tree.vfsPath("b"),
            chunkSize: 4
        )
        #expect(!equal)

        let same = try ByteComparator.localFilesEqual(
            tree.vfsPath("a"),
            tree.vfsPath("a"),
            chunkSize: 4
        )
        #expect(same)
    }

    @Test("comparing a non-local path throws unsupported")
    func nonLocalThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "x")
        let remote = VFSPath(backend: VFSBackendID("sftp"), path: "/a")

        #expect {
            try ByteComparator.localFilesEqual(tree.vfsPath("a"), remote)
        } throws: { error in
            if case .unsupported = error as? VFSError { return true }
            return false
        }
    }

    @Test("comparing a directory throws unsupported")
    func directoryThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("dir")
        try tree.writeFile("file", contents: "x")

        #expect {
            try ByteComparator.localFilesEqual(tree.vfsPath("dir"), tree.vfsPath("file"))
        } throws: { error in
            if case .unsupported = error as? VFSError { return true }
            return false
        }
    }

    @Test("cancellation aborts before reading the first chunk")
    func cancels() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "0123456789")
        try tree.writeFile("b", contents: "0123456789")

        #expect(throws: CancellationError.self) {
            try ByteComparator.localFilesEqual(tree.vfsPath("a"), tree.vfsPath("b")) { true }
        }
    }
}
