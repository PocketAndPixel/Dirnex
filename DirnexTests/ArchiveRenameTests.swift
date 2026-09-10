import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Renaming a member of a browsed archive — F2's second route (PLAN.md §M4 archive writes).
///
/// It is `delete`'s twin one verb over: the same extract → edit the staged tree → repack → atomic
/// swap, with a `moveItem` where that one has a `removeItem`. So the claims worth pinning are the
/// ones the shape buys and the ones it does not — that the member really moves *and keeps its
/// bytes*, that everything else in the container survives, and above all that **every refusal
/// leaves the original exactly where it was**, since a half-rewritten archive is unrecoverable in a
/// way a failed one is not.
@Suite("Renaming inside an archive")
struct ArchiveRenameTests {
    // MARK: - The rewrite

    @Test("a renamed member keeps its bytes, and its neighbours survive")
    func renameKeepsBytesAndNeighbours() throws {
        let fixture = try Fixture()

        try ArchiveWriter.rename(
            innerPath: "/one.txt", to: "renamed.txt",
            inArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(try fixture.members() == ["renamed.txt", "two.txt"])
        // The bytes are the assertion, not the name: a rewrite that recreated the member empty
        // would satisfy every listing while losing the file.
        #expect(try fixture.readBack("renamed.txt") == "first")
        #expect(try fixture.readBack("two.txt") == "second")
    }

    @Test("a member in a subdirectory stays in it")
    func renameKeepsTheDirectory() throws {
        let fixture = try Fixture(nesting: true)

        try ArchiveWriter.rename(
            innerPath: "/docs/deep.txt", to: "other.md",
            inArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(try fixture.members().contains("docs/other.md"))
        #expect(try fixture.readBack("docs/other.md") == "deep")
    }

    /// A directory renames with its whole subtree, because the staged edit is one `moveItem` over a
    /// real directory rather than anything that has to enumerate members.
    @Test("renaming a folder carries its contents")
    func renameCarriesASubtree() throws {
        let fixture = try Fixture(nesting: true)

        try ArchiveWriter.rename(
            innerPath: "/docs", to: "guides",
            inArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(try fixture.members().contains("guides/deep.txt"))
        #expect(try fixture.readBack("guides/deep.txt") == "deep")
    }

    /// The one place this differs from the local rename, measured rather than assumed:
    /// `FileManager.moveItem` performs a case-only change on case-insensitive APFS instead of
    /// refusing it as a collision. Without it a case fix would be impossible inside an archive while
    /// working everywhere else in the app.
    @Test("a case-only change is a rename like any other")
    func renameAllowsACaseOnlyChange() throws {
        let fixture = try Fixture()

        try ArchiveWriter.rename(
            innerPath: "/one.txt", to: "ONE.txt",
            inArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(try fixture.members() == ["ONE.txt", "two.txt"])
        #expect(try fixture.readBack("ONE.txt") == "first")
    }

    // MARK: - Refusals leave the archive alone

    @Test("renaming onto an existing member is refused and changes nothing")
    func renameRefusesACollision() throws {
        let fixture = try Fixture()
        let before = try fixture.archiveBytes()

        #expect(throws: (any Error).self) {
            try ArchiveWriter.rename(
                innerPath: "/one.txt", to: "two.txt",
                inArchiveAt: fixture.archive, undo: fixture.undo
            )
        }

        // Byte-identical, which is the claim: the refusal happens inside the staged tree, so the
        // container is never repacked and the member it would have replaced keeps its own bytes.
        #expect(try fixture.archiveBytes() == before)
        #expect(try fixture.readBack("two.txt") == "second")
    }

    /// `..` is refused *before* the archive is opened, so a name that was never usable costs no
    /// extract — and, more importantly, cannot climb out of the directory the member was in once the
    /// tree is staged on a real filesystem.
    @Test("a name that would move the member out of its folder is refused")
    func renameRefusesATraversal() throws {
        let fixture = try Fixture(nesting: true)
        let before = try fixture.archiveBytes()

        for bad in ["..", "../escape.txt", "sub/deep.txt", ""] {
            #expect(throws: (any Error).self) {
                try ArchiveWriter.rename(
                    innerPath: "/docs/deep.txt", to: bad,
                    inArchiveAt: fixture.archive, undo: fixture.undo
                )
            }
        }
        #expect(try fixture.archiveBytes() == before)
    }

    @Test("a missing member is refused and changes nothing")
    func renameRefusesAMissingMember() throws {
        let fixture = try Fixture()
        let before = try fixture.archiveBytes()

        #expect(throws: (any Error).self) {
            try ArchiveWriter.rename(
                innerPath: "/not-there.txt", to: "whatever.txt",
                inArchiveAt: fixture.archive, undo: fixture.undo
            )
        }
        #expect(try fixture.archiveBytes() == before)
    }

    // MARK: - What the rewrite has to preserve

    /// The same claim the delete twin pins, and for the same reason: an archive that came back in
    /// the clear would be the quietest possible loss of protection.
    @Test("an encrypted archive stays encrypted, and the renamed member still opens")
    func renamePreservesEncryption() throws {
        let fixture = try Fixture(encryption: .aes256)

        try ArchiveWriter.rename(
            innerPath: "/one.txt", to: "renamed.txt",
            inArchiveAt: fixture.archive,
            passphrase: Fixture.passphrase, undo: fixture.undo
        )

        let inspection = try EncryptedArchiveReader.inspect(archiveAt: fixture.archive)
        #expect(inspection.needsPassphrase)
        #expect(inspection.entries.map(\.archivePath).sorted() == ["renamed.txt", "two.txt"])
        let unprotected = inspection.entries.filter { !$0.isEncrypted }.map(\.archivePath)
        #expect(unprotected.isEmpty)
    }

    /// ⌘Z has to be able to put the container back, exactly as it can after a delete or an add —
    /// which is what makes a rename affordable without the confirmation F8 raises.
    @Test("a rename is undoable")
    func renameIsUndoable() throws {
        let fixture = try Fixture()

        let snapshot = try ArchiveWriter.rename(
            innerPath: "/one.txt", to: "renamed.txt",
            inArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(snapshot != nil, "the rewrite kept no copy to undo from")
    }

    // MARK: - Which rows F2 takes this route for

    /// The narrowness control the reach table cannot reach, because it needs a host: a **nested**
    /// archive's own bytes are an extracted temp copy, so a rewrite would land somewhere thrown
    /// away — the same line F8, paste and the write-back already draw.
    ///
    /// Without it "an archive member renames" would be implemented as "every archive member
    /// renames", and the failure is the expensive kind: the rewrite would succeed, report success,
    /// and change nothing the user can see.
    @MainActor
    @Test("a member of a nested archive is refused, where a top-level one is not")
    func nestedArchiveMembersAreRefused() throws {
        let outer = "/Users/tester/outer.zip"
        let extracted = "/tmp/dirnex-nested/inner.zip"
        let host = StubPanelHost()
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: VFSPath(backend: .archive(forArchiveAt: outer), path: "/"),
            restorationKey: nil
        )
        pane.host = host

        let topLevel = VFSPath(backend: .archive(forArchiveAt: outer), path: "/one.txt")
        #expect(
            pane.renameRoute(for: topLevel) == .archiveMember(archiveOnDiskPath: outer)
        )

        // Recorded exactly as `beginNestedArchiveEntry` records it when ⏎ opens an inner archive.
        host.nestedArchiveRegistry.record(
            mountOnDiskPath: extracted,
            origin: VFSPath(backend: .archive(forArchiveAt: outer), path: "/inner.zip")
        )
        let nested = VFSPath(backend: .archive(forArchiveAt: extracted), path: "/deep.txt")
        #expect(pane.renameRoute(for: nested) == .unavailable)
    }

    /// The other half of the same control: the archive branch is answered *before* the capability,
    /// so it has to leave every non-archive row on the route it always took. Reverted to answer
    /// `.archiveMember` for everything, the whole local rename would silently become a rewrite of
    /// an archive that does not exist.
    @MainActor
    @Test("an ordinary local row still renames through the backend")
    func localRowsKeepTheBackendRoute() {
        let directory = VFSPath.local(NSHomeDirectory() + "/Documents")
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: directory,
            restorationKey: nil
        )

        #expect(pane.renameRoute(for: directory.appending("note.txt")) == .backend)
    }

    // MARK: - Fixture

    private struct Fixture {
        static let passphrase = ArchivePassphrase("correct horse")

        let directory: URL
        let archive: String
        /// Captured here rather than into the app's own store, which in this target is the
        /// *developer's* `~/Library/Application Support/Dirnex` — see `ArchiveUndoStorage.Request`
        /// for why `undo:` has no default.
        let undo: ArchiveUndoStorage.Request

        init(encryption: ArchiveEncryption = .none, nesting: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveRename-\(UUID().uuidString)")
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "first".write(
                to: source.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8
            )
            try "second".write(
                to: source.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8
            )
            var names = ["one.txt", "two.txt"]
            if nesting {
                let docs = source.appendingPathComponent("docs", isDirectory: true)
                try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
                try "deep".write(
                    to: docs.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8
                )
                names.append("docs")
            }

            undo = ArchiveUndoStorage.Request(
                store: ArchiveUndoStore(
                    root: directory.appendingPathComponent("undo-store", isDirectory: true)
                ),
                live: []
            )
            archive = directory.appendingPathComponent("fixture.zip").path
            try EncryptedArchiveWriter.write(
                items: try ArchiveSourceEnumerator.items(inDirectory: source.path, names: names),
                toArchiveAt: archive,
                encryption: encryption,
                passphrase: encryption.isEncrypted ? Self.passphrase : nil
            )
        }

        func archiveBytes() throws -> Data {
            try Data(contentsOf: URL(fileURLWithPath: archive))
        }

        /// Every member's inner path, read back through the reader rather than through the writer
        /// that produced it — so the two cannot agree with each other about something neither has
        /// right.
        ///
        /// The **`./` prefix is normalized away**, and that is a fact about the repack rather than
        /// something being hidden: the unencrypted route packs `.`, so every entry it writes comes
        /// back `./name` where the libarchive route writes `name` (docs/NOTES.md ▸ Design lessons).
        /// It is pre-existing and both spellings browse identically — but it is why the encrypted
        /// test here passed while its plain twin did not, which read as a broken rename until the
        /// two argvs were run side by side.
        func members() throws -> [String] {
            try EncryptedArchiveReader.inspect(archiveAt: archive)
                .entries
                .map(\.archivePath)
                .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
                .filter { !$0.isEmpty && !$0.hasSuffix("/") }
                .sorted()
        }

        /// The member's bytes, extracted whole rather than by member filter — the filter matches the
        /// name **as stored**, which the two repack routes spell differently, so filtering here
        /// would make the reader route-dependent for no gain.
        func readBack(_ innerPath: String) throws -> String {
            let out = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            _ = try EncryptedArchiveReader.extract(
                archiveAt: archive, into: out.path, passphrase: Self.passphrase
            )
            return try String(
                contentsOfFile: out.appendingPathComponent(innerPath).path, encoding: .utf8
            )
        }
    }
}
