import Foundation
import os
import Testing

@testable import DirnexCore

/// The in-process reader opens a `.tar.zst` through the `zstd` that ``ZstdTool`` found, by its
/// absolute path rather than through this process's `PATH`.
///
/// `swift test` from a shell inherits that shell's `PATH`, where Homebrew's `zstd` usually is, so a
/// plain read would pass whatever the reader did. Each test therefore points the search at a
/// directory holding a stand-in `zstd` that records its arguments and then runs the real one, and
/// asserts on the record: only the reader's own filter can have run the stand-in.
@Suite(
    "Reading a .tar.zst in process",
    .enabled(if: ZstdTool.locate() != nil, "needs a real zstd for the stand-in to run")
)
struct ZstdArchiveReaderTests {
    /// A directory holding a `zstd` script that appends its arguments to `record`, then runs the
    /// real one. libarchive starts it with an empty environment, so both paths are written into the
    /// script rather than passed.
    private struct RecordingZstd {
        let directory: String
        let record: String

        init() throws {
            let real = try #require(ZstdTool.locate())
            directory = NSTemporaryDirectory() + "dirnex-zstd-stand-in-\(UUID().uuidString)"
            record = directory + "/runs.txt"
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
            let script = "#!/bin/sh\necho \"$*\" >> '\(record)'\nexec '\(real)' \"$@\"\n"
            FileManager.default.createFile(
                atPath: directory + "/zstd", contents: Data(script.utf8),
                attributes: [.posixPermissions: 0o755]
            )
        }

        var runs: [String] {
            let text = (try? String(contentsOfFile: record, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }

        func remove() { try? FileManager.default.removeItem(atPath: directory) }
    }

    @Test(
        "a .tar.zst is listed through zstd at the path that was found",
        arguments: ["plain-bsdtar", "plain-pzstd"]
    )
    func inspectsThroughTheFoundZstd(_ name: String) throws {
        let stand = try RecordingZstd()
        defer { stand.remove() }
        let archive = try ZstdFixture.archive(name)

        let inspection = try ZstdTool.$searchDirectoriesOverride.withValue([stand.directory]) {
            try EncryptedArchiveReader.inspect(archiveAt: archive)
        }
        #expect(inspection.entries.map(\.archivePath) == ["alpha.txt", "docs/", "docs/beta.txt"])
        #expect(stand.runs == ["-d -qq"])
    }

    @Test("a .tar.zst extracts through the zstd that was found")
    func extractsThroughTheFoundZstd() throws {
        let stand = try RecordingZstd()
        defer { stand.remove() }
        let archive = try ZstdFixture.archive("plain-bsdtar")
        let destination = try EncryptedArchiveFixture.scratchDirectory()
        defer { EncryptedArchiveFixture.remove(destination) }

        try ZstdTool.$searchDirectoriesOverride.withValue([stand.directory]) {
            try EncryptedArchiveReader.extract(
                archiveAt: archive, into: destination, passphrase: nil
            )
        }
        #expect(try EncryptedArchiveFixture.contents(of: destination + "/alpha.txt") == "alpha\n")
        #expect(try EncryptedArchiveFixture.contents(of: destination + "/docs/beta.txt") == "beta\n")
        // One run for the inspection, one for the extraction pass.
        #expect(stand.runs == ["-d -qq", "-d -qq"])
    }

    @Test("with no zstd found, the reader registers no filter of its own")
    func noZstdRegistersNothing() throws {
        // The negative control for the two above: whatever libarchive's own filter then does with
        // this process's PATH, the stand-in is never run.
        let stand = try RecordingZstd()
        defer { stand.remove() }
        let archive = try ZstdFixture.archive("plain-bsdtar")

        _ = try? ZstdTool.$searchDirectoriesOverride.withValue([]) {
            try EncryptedArchiveReader.inspect(archiveAt: archive)
        }
        #expect(stand.runs.isEmpty)
    }

    @Test("concurrent reads of a .tar.zst all finish")
    func concurrentReadsFinish() throws {
        // libarchive leaks each zstd child's pipes into the next one it spawns, and two children
        // holding each other's stdin never exit (`ArchiveReadHandle.takeExternalProgramTurn`).
        // Without the turn this never finishes, so it waits on a deadline rather than on the
        // reads: a regression fails here, and leaves its stuck `zstd` children to be killed.
        // The reads run on threads of their own, not a global queue, which starts nothing while
        // every cooperative thread is busy: with three free, as on CI, they never began and the
        // wait ran out (docs/NOTES.md ▸ Testing).
        let archive = try ZstdFixture.archive("plain-bsdtar")
        let reads = 8
        let listed = OSAllocatedUnfairLock(initialState: 0)
        let finished = DispatchSemaphore(value: 0)
        for _ in 0..<reads {
            Thread {
                let count = (try? EncryptedArchiveReader.inspect(archiveAt: archive))?.entries.count
                if count == 3 { listed.withLock { $0 += 1 } }
                finished.signal()
            }.start()
        }
        let deadline = DispatchTime.now() + 30
        #expect((0..<reads).allSatisfy { _ in finished.wait(timeout: deadline) == .success })
        #expect(listed.withLock { $0 } == reads)
    }

    @Test("a zip is not handed to zstd")
    func otherFormatsKeepTheirFilters() throws {
        let stand = try RecordingZstd()
        defer { stand.remove() }
        let zip = try EncryptedArchiveFixture.archive("plain-bsdtar")

        let inspection = try ZstdTool.$searchDirectoriesOverride.withValue([stand.directory]) {
            try EncryptedArchiveReader.inspect(archiveAt: zip)
        }
        #expect(!inspection.entries.isEmpty)
        #expect(stand.runs.isEmpty)
    }
}
