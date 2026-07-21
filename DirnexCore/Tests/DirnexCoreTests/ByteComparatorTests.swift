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

    // MARK: - prescan (the "is this worth opening a diff tool for?" pre-flight)

    @Test("prescan reports identical files, so the caller can skip the launch")
    func prescanIdentical() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "hello world")
        try tree.writeFile("b", contents: "hello world")

        #expect(try ByteComparator.prescan(tree.vfsPath("a"), tree.vfsPath("b")) == .identical)
    }

    @Test("prescan reports differing files")
    func prescanDifferent() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "aaaa")
        try tree.writeFile("b", contents: "aaba")

        #expect(try ByteComparator.prescan(tree.vfsPath("a"), tree.vfsPath("b")) == .different)
    }

    @Test("a path prescanned against itself is identical without a read")
    func prescanSamePath() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "hello")

        #expect(try ByteComparator.prescan(tree.vfsPath("a"), tree.vfsPath("a")) == .identical)
    }

    @Test("a file past the byte limit is reported unscanned, carrying the larger size")
    func prescanTooLarge() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", bytes: 100)
        try tree.writeFile("b", bytes: 100)

        let outcome = try ByteComparator.prescan(
            tree.vfsPath("a"),
            tree.vfsPath("b"),
            byteLimit: 64
        )
        #expect(outcome == .tooLargeToScan(largestByteSize: 100))
    }

    /// The size gate deliberately outranks the free answer: two differently-sized 2 GB files are
    /// known-unequal without reading a byte, but that is not a reason to hand them to FileMerge.
    @Test("the size gate wins over the size-mismatch short-circuit")
    func prescanTooLargeBeatsSizeMismatch() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", bytes: 100)
        try tree.writeFile("b", bytes: 250)

        let outcome = try ByteComparator.prescan(
            tree.vfsPath("a"),
            tree.vfsPath("b"),
            byteLimit: 64
        )
        #expect(outcome == .tooLargeToScan(largestByteSize: 250))
    }

    @Test("a file exactly at the byte limit is still scanned")
    func prescanAtLimit() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", bytes: 64)
        try tree.writeFile("b", bytes: 64)

        let outcome = try ByteComparator.prescan(
            tree.vfsPath("a"),
            tree.vfsPath("b"),
            byteLimit: 64
        )
        #expect(outcome == .identical)
    }

    @Test("prescanning a non-local path throws unsupported")
    func prescanNonLocalThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "hello")
        let remote = VFSPath(backend: VFSBackendID("sftp"), path: "/a")

        #expect {
            try ByteComparator.prescan(tree.vfsPath("a"), remote)
        } throws: { error in
            if case .unsupported = error as? VFSError { return true }
            return false
        }
    }
}
