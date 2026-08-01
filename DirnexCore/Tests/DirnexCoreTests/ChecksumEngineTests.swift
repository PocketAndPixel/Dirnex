import Foundation
import Testing

@testable import DirnexCore

/// Every expected digest below was produced by the *system* tools — `/usr/bin/crc32`, `md5 -q`,
/// `shasum -a 1`, `shasum -a 256` — over the same bytes, not by this engine. A fixture the engine
/// computed would only prove it agrees with itself.
@Suite("ChecksumEngine")
struct ChecksumEngineTests {
    // MARK: - Accumulator

    @Test("all four algorithms over the empty input match the system tools")
    func emptyInput() {
        let digests = ChecksumAccumulator(algorithms: Set(ChecksumAlgorithm.allCases)).finalized()
        #expect(digests[.crc32] == "00000000")
        #expect(digests[.md5] == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(digests[.sha1] == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(digests[.sha256]
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(digests.byteSize == 0)
    }

    @Test("all four algorithms over real bytes match the system tools")
    func fourAlgorithmsInOnePass() {
        var accumulator = ChecksumAccumulator(algorithms: Set(ChecksumAlgorithm.allCases))
        accumulator.update(Data("hello checksum world\n".utf8))
        let digests = accumulator.finalized()

        #expect(digests[.crc32] == "4dbf2cc1")
        #expect(digests[.md5] == "81f90f926b3e019b743181fd8cdff9bb")
        #expect(digests[.sha1] == "2a088a888aa0f73a2c91f313b7d7c4b4ce047770")
        #expect(digests[.sha256]
            == "54b546dd1abc7108f73affc828b0771155ac437c380a245f1f183ca4d455c5fc")
        #expect(digests.byteSize == 21)
    }

    @Test("an accumulator computes only what it was asked for")
    func selectiveAlgorithms() {
        var accumulator = ChecksumAccumulator(algorithms: [.md5])
        accumulator.update(Data("hello checksum world\n".utf8))
        let digests = accumulator.finalized()

        #expect(digests.algorithms == [.md5])
        #expect(digests[.sha256] == nil)
        #expect(digests[.md5] == "81f90f926b3e019b743181fd8cdff9bb")
    }

    @Test("an empty algorithm set digests nothing but still counts bytes")
    func noAlgorithms() {
        var accumulator = ChecksumAccumulator(algorithms: [])
        accumulator.update(Data("hello checksum world\n".utf8))
        let digests = accumulator.finalized()

        #expect(digests.isEmpty)
        #expect(digests.algorithms.isEmpty)
        #expect(digests.byteSize == 21)
    }

    @Test("chunk boundaries do not change any of the four digests")
    func chunkingIsTransparent() {
        let payload = Data("the quick brown fox jumps over the lazy dog".utf8)
        var whole = ChecksumAccumulator(algorithms: Set(ChecksumAlgorithm.allCases))
        whole.update(payload)

        var split = ChecksumAccumulator(algorithms: Set(ChecksumAlgorithm.allCases))
        for start in stride(from: 0, to: payload.count, by: 5) {
            split.update(payload[start..<min(start + 5, payload.count)])
        }
        #expect(split.finalized() == whole.finalized())
    }

    /// Digest order is `allCases`, never dictionary order, so a multi-algorithm display or a
    /// written manifest comes out the same on every run.
    @Test("digests report their algorithms in a stable order")
    func stableOrdering() {
        let digests = ChecksumAccumulator(algorithms: [.sha256, .crc32, .md5]).finalized()
        #expect(digests.algorithms == [.crc32, .md5, .sha256])
    }

    // MARK: - Files

    @Test("a file's digests match the system tools")
    func fileDigests() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("hello.txt", contents: "hello checksum world\n")

        let digests = try ChecksumEngine.digests(
            of: tree.vfsPath("hello.txt"),
            using: Set(ChecksumAlgorithm.allCases)
        )
        #expect(digests[.crc32] == "4dbf2cc1")
        #expect(digests[.md5] == "81f90f926b3e019b743181fd8cdff9bb")
        #expect(digests[.sha1] == "2a088a888aa0f73a2c91f313b7d7c4b4ce047770")
        #expect(digests[.sha256]
            == "54b546dd1abc7108f73affc828b0771155ac437c380a245f1f183ca4d455c5fc")
        #expect(digests.byteSize == 21)
    }

    @Test("the default is SHA-256 alone")
    func defaultAlgorithm() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("hello.txt", contents: "hello checksum world\n")

        let digests = try ChecksumEngine.digests(of: tree.vfsPath("hello.txt"))
        #expect(digests.algorithms == [.sha256])
    }

    /// 300 KiB of `x` spans three 128 KiB chunks, so the read loop's boundary handling is exercised
    /// against a digest the system tools produced over the identical file.
    @Test("a multi-chunk file hashes correctly and reports progress")
    func multiChunkFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("big.bin", bytes: 300 * 1024)

        var progress: [Int64] = []
        let digests = try ChecksumEngine.digests(
            of: tree.vfsPath("big.bin"),
            using: Set(ChecksumAlgorithm.allCases),
            onProgress: { progress.append($0) }
        )

        #expect(digests[.crc32] == "47621502")
        #expect(digests[.md5] == "0f305b0a4004409d41c67fbc6e224d6d")
        #expect(digests[.sha1] == "2c23c1bc63e9f3dff5e2c3a943da5626b36129c6")
        #expect(digests[.sha256]
            == "def89517b7d1690aac7628fccbe266a6c5b30c4bc4e4e226b2f32e27a370a588")

        let expectedSize: Int64 = 307_200
        #expect(digests.byteSize == expectedSize)
        #expect(progress.count == 3)
        #expect(progress.last == expectedSize)
        let isMonotonic = zip(progress, progress.dropFirst()).allSatisfy { $0 < $1 }
        #expect(isMonotonic)
    }

    @Test("an empty file hashes to the empty digests")
    func emptyFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("empty.bin", bytes: 0)

        let digests = try ChecksumEngine.digests(of: tree.vfsPath("empty.bin"), using: [.sha256])
        #expect(digests[.sha256]
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(digests.byteSize == 0)
    }

    /// `stat`, not `lstat`: `shasum` through a symlink hashes the target, and so does this.
    @Test("a symlink is hashed as its target")
    func symlinkFollowsTarget() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("hello.txt", contents: "hello checksum world\n")
        try tree.symlink("link.txt", to: tree.path("hello.txt"))

        let digests = try ChecksumEngine.digests(of: tree.vfsPath("link.txt"), using: [.md5])
        #expect(digests[.md5] == "81f90f926b3e019b743181fd8cdff9bb")
    }

    // MARK: - Guards

    @Test("a directory is refused")
    func directoryRefused() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("folder")

        #expect(throws: ChecksumError.needsRegularFile) {
            try ChecksumEngine.digests(of: tree.vfsPath("folder"))
        }
    }

    @Test("a non-local path is refused before any I/O")
    func remotePathRefused() {
        let remote = VFSPath(backend: VFSBackendID("sftp"), path: "/home/oleg/disk.iso")
        #expect(throws: ChecksumError.needsLocalFile) {
            try ChecksumEngine.digests(of: remote)
        }
    }

    @Test("a missing file throws a VFS error, not a checksum error")
    func missingFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        #expect(throws: VFSError.notFound(tree.vfsPath("nope.txt"))) {
            try ChecksumEngine.digests(of: tree.vfsPath("nope.txt"))
        }
    }

    @Test("cancellation abandons the read")
    func cancellation() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("big.bin", bytes: 300 * 1024)

        #expect(throws: CancellationError.self) {
            try ChecksumEngine.digests(of: tree.vfsPath("big.bin"), isCancelled: { true })
        }
    }
}
