import Foundation
import Testing

@testable import DirnexCore

/// What lets a path-keyed archive cache notice that the path now names a *different* archive
/// (PLAN.md §M4). Every case runs against real files, because the whole value of the type is what
/// the filesystem does to the inode when an archive is deleted and packed again under its name —
/// a hand-built fixture could only prove the comparison agrees with itself.
@Suite("Archive identity")
struct ArchiveIdentityTests {
    @Test("an untouched file keeps its identity")
    func stableWhileUntouched() throws {
        let file = try TempFile(contents: "one")
        let identity = try #require(ArchiveIdentity.current(ofFileAt: file.path))

        #expect(ArchiveIdentity.current(ofFileAt: file.path) == identity)
        #expect(identity.stillDescribesFile(at: file.path))
    }

    @Test("a file deleted and written again under the same name is a different identity")
    func replacementIsDetected() throws {
        let file = try TempFile(contents: "one")
        let before = try #require(ArchiveIdentity.current(ofFileAt: file.path))

        // The reported bug's exact gesture: remove the archive, pack a new one under the same name.
        try file.replace(contents: "two")

        #expect(!before.stillDescribesFile(at: file.path))
        #expect(ArchiveIdentity.current(ofFileAt: file.path) != before)
    }

    @Test("the replacement is caught by the inode even when size and mtime match")
    func replacementOfIdenticalSizeAndDateIsDetected() throws {
        // A whole second, so the two writes carry a byte-identical `st_mtimespec` — setting a
        // timestamp read back off the first file would keep its nanoseconds and differ by them.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let file = try TempFile(contents: "one")
        try file.setModificationDate(stamp)
        let before = try #require(ArchiveIdentity.current(ofFileAt: file.path))

        try file.replace(contents: "two") // same byte count
        try file.setModificationDate(stamp)

        let after = try #require(ArchiveIdentity.current(ofFileAt: file.path))
        // Size and timestamp alone would call these the same file — this is why the inode is in
        // the identity at all, and why `EditedFileRevision`'s size+date pair can't be reused here.
        #expect(after.byteSize == before.byteSize)
        #expect(after.modified == before.modified)
        #expect(after != before)
    }

    @Test("an in-place rewrite keeping the inode is caught by the size")
    func inPlaceRewriteIsDetected() throws {
        let file = try TempFile(contents: "one")
        let before = try #require(ArchiveIdentity.current(ofFileAt: file.path))

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file.path))
        try handle.write(contentsOf: Data("one and more".utf8))
        try handle.close()

        let after = try #require(ArchiveIdentity.current(ofFileAt: file.path))
        #expect(after.inode == before.inode)
        #expect(after != before)
    }

    @Test("a missing file has no identity, and no cache may claim it does")
    func missingFileHasNoIdentity() throws {
        let file = try TempFile(contents: "one")
        let identity = try #require(ArchiveIdentity.current(ofFileAt: file.path))
        try FileManager.default.removeItem(atPath: file.path)

        #expect(ArchiveIdentity.current(ofFileAt: file.path) == nil)
        // Deliberately *not* "unchanged": the caller must re-read and surface the real failure
        // rather than answer from a snapshot of a file that is gone.
        #expect(!identity.stillDescribesFile(at: file.path))
    }

    @Test("the symlinked archive is the target, so repointing the link is a new identity")
    func symlinkFollowsItsTarget() throws {
        let first = try TempFile(contents: "one")
        let second = try TempFile(contents: "two")
        let link = first.directory.appendingPathComponent("link.zip").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: first.path)

        let before = try #require(ArchiveIdentity.current(ofFileAt: link))
        #expect(before == ArchiveIdentity.current(ofFileAt: first.path))

        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: second.path)
        // What is identified is the bytes the archive reader will read, not the link itself.
        #expect(!before.stillDescribesFile(at: link))
    }

    /// A real file in its own temp directory, removed with the test.
    private final class TempFile {
        let directory: URL
        let path: String

        init(contents: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveIdentityTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("pkg.zip").path
            try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        }

        func setModificationDate(_ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }

        func replace(contents: String) throws {
            try FileManager.default.removeItem(atPath: path)
            try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
