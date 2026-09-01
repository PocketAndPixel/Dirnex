import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// One rewrite absorbing several edited members, against **real archives**
/// (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// The grouping is pinned next door with no `bsdtar`; what only this can ask is whether the pass it
/// produces is really one pass and really lands everything — including members that came from
/// *different folders* inside the archive, which is the case the old single-directory spelling
/// could not express at all.
@Suite("Archive multi-directory add")
struct ArchiveMultiAddTests {
    @Test("several edited members land in one rewrite, from different inner folders")
    func oneRewriteAbsorbsSeveralFolders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let root = try fixture.edited("one.txt", contents: "edited one")
        let nested = try fixture.edited("deep.txt", contents: "edited deep")
        try ArchiveWriter.add(
            [
                ArchiveMutation.Addition(localPath: root, innerDirectory: "/"),
                ArchiveMutation.Addition(localPath: nested, innerDirectory: "/docs")
            ],
            ofArchiveAt: fixture.archive,
            undo: fixture.undo
        )

        // Both landed, each where it was told, and the untouched member survived.
        #expect(try fixture.members().contains("./one.txt"))
        #expect(try fixture.members().contains("./docs/deep.txt"))
        #expect(try fixture.members().contains("./two.txt"))
        #expect(try fixture.readBack("one.txt") == "edited one")
        #expect(try fixture.readBack("docs/deep.txt") == "edited deep")
        #expect(try fixture.readBack("two.txt") == "second")
    }

    @Test("it really is one rewrite, not one per folder")
    func itIsASinglePass() throws {
        // The claim the whole change rests on, and the archive's own **inode** is what settles it:
        // every rewrite ends in an atomic swap onto a freshly packed file, so N passes would leave
        // N-1 discarded containers behind and the file would have been replaced N times. One add
        // over three folders replaces it exactly once.
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let before = try fixture.inode()

        try ArchiveWriter.add(
            [
                ArchiveMutation.Addition(
                    localPath: try fixture.edited("a.txt", contents: "a"), innerDirectory: "/"
                ),
                ArchiveMutation.Addition(
                    localPath: try fixture.edited("b.txt", contents: "b"), innerDirectory: "/docs"
                ),
                ArchiveMutation.Addition(
                    localPath: try fixture.edited("c.txt", contents: "c"),
                    innerDirectory: "/docs/api"
                )
            ],
            ofArchiveAt: fixture.archive,
            undo: fixture.undo
        )
        #expect(try fixture.inode() != before)
        // One snapshot in the undo store, which is the same fact from the other side: a copy of the
        // container is taken per rewrite, so three passes would have held three.
        #expect(fixture.storeContents().count == 1)
    }

    @Test("the single-directory spelling still behaves exactly as it did")
    func singleDirectorySpellingIsUnchanged() throws {
        // The narrowness half: `add(localPaths:toInnerDirectory:)` is now one call into the general
        // form, and every existing caller — a paste, a drag, an add from the other pane — has to be
        // untouched by that.
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.edited("x.txt", contents: "x")
        let second = try fixture.edited("y.txt", contents: "y")

        try ArchiveWriter.add(
            localPaths: [first, second],
            toInnerDirectory: "/docs",
            ofArchiveAt: fixture.archive,
            undo: fixture.undo
        )
        #expect(try fixture.readBack("docs/x.txt") == "x")
        #expect(try fixture.readBack("docs/y.txt") == "y")
        #expect(try fixture.readBack("one.txt") == "first")
    }

    @Test("a later addition of the same member wins")
    func lastWriteWins() throws {
        // Which is why the grouping preserves the order saves were gathered in: `add` replaces as
        // it goes, so for two saves of one member the newest has to be last.
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let older = try fixture.edited("one.txt", contents: "older", as: "older")
        let newer = try fixture.edited("one.txt", contents: "newer", as: "newer")

        try ArchiveWriter.add(
            [
                ArchiveMutation.Addition(localPath: older, innerDirectory: "/"),
                ArchiveMutation.Addition(localPath: newer, innerDirectory: "/")
            ],
            ofArchiveAt: fixture.archive,
            undo: fixture.undo
        )
        #expect(try fixture.readBack("one.txt") == "newer")
    }

    /// A real two-member zip and a place to put edited copies.
    private struct Fixture {
        let directory: URL
        let archive: String
        let undo: ArchiveUndoStorage.Request

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveMultiAdd-\(UUID().uuidString)")
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "first".write(
                to: source.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8
            )
            try "second".write(
                to: source.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8
            )
            undo = ArchiveUndoStorage.Request(
                store: ArchiveUndoStore(root: directory.appendingPathComponent("undo-store")),
                live: []
            )
            archive = directory.appendingPathComponent("fixture.zip").path
            try EncryptedArchiveWriter.write(
                items: try ArchiveSourceEnumerator.items(
                    inDirectory: source.path, names: ["one.txt", "two.txt"]
                ),
                toArchiveAt: archive,
                encryption: .none,
                passphrase: nil,
                namePrivacy: .visible
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }

        /// An edited copy, in its own directory so two versions of one name can coexist — which is
        /// exactly the shape a batch of write-backs has (`MaterializeRunner` gives every fetched
        /// row its own directory for the same reason).
        func edited(_ name: String, contents: String, as slot: String = "edit") throws -> String {
            let holder = directory.appendingPathComponent("\(slot)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
            let path = holder.appendingPathComponent(name)
            try contents.write(to: path, atomically: true, encoding: .utf8)
            return path.path
        }

        func members() throws -> [String] {
            try EncryptedArchiveReader.inspect(archiveAt: archive).entries
                .map(\.archivePath).sorted()
        }

        func inode() throws -> UInt64 {
            var info = Darwin.stat()
            #expect(lstat(archive, &info) == 0)
            return info.st_ino
        }

        func storeContents() -> [String] {
            (undo.store?.held() ?? []).map(\.path)
        }

        func readBack(_ innerPath: String) throws -> String {
            let out = directory.appendingPathComponent("read-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: out) }
            _ = try EncryptedArchiveReader.extract(
                archiveAt: archive, into: out.path, passphrase: nil
            )
            return try String(
                contentsOf: out.appendingPathComponent(innerPath), encoding: .utf8
            )
        }
    }
}
