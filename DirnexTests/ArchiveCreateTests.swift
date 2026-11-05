import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// F7 New Folder and ⇧F4's new file inside a browsed archive (taken 2026-11-05).
///
/// Rename's twin, so the claims are rename's: the new member really is in the rewritten archive and
/// is the kind asked for, everything else in the container survives with its bytes, the container
/// keeps its format and its encryption, and **every refusal leaves the original byte-identical**,
/// since a half-rewritten archive is unrecoverable in a way a failed one is not.
///
/// The writer is driven directly with a scratch undo store. A successful create through a *pane*
/// would capture into `ArchiveUndoStorage.shared`, which in this target is the developer's own
/// `~/Library/Application Support/Dirnex`, so the pane is driven only to a refusal, which captures
/// nothing (the copy is taken after the repack, and a refused create never gets that far).
@Suite("Creating inside an archive")
struct ArchiveCreateTests {
    // MARK: - The rewrite

    @Test("F7 makes an empty folder, and the members beside it keep their bytes")
    func makesAFolder() throws {
        let fixture = try Fixture()

        try ArchiveWriter.create(
            .folder, named: "untitled folder", inInnerDirectory: "/",
            ofArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(try fixture.kind(of: "untitled folder") == .directory)
        #expect(try fixture.files() == ["docs/deep.txt", "one.txt", "two.txt"])
        #expect(try fixture.readBack("one.txt") == "first")
        #expect(try fixture.readBack("docs/deep.txt") == "deep")
    }

    @Test("a new folder goes in the folder it was made in")
    func makesAFolderInAFolder() throws {
        let fixture = try Fixture()

        try ArchiveWriter.create(
            .folder, named: "inner", inInnerDirectory: "/docs",
            ofArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(try fixture.kind(of: "docs/inner") == .directory)
        #expect(try fixture.kind(of: "inner") == nil)
        #expect(try fixture.readBack("docs/deep.txt") == "deep")
    }

    /// The member ⇧F4 then hands to the editor: a real, empty regular file, so F4's own route can
    /// extract it and the write-back can replace it on the first save.
    @Test("⇧F4's new member is an empty file")
    func makesAnEmptyFile() throws {
        let fixture = try Fixture()

        try ArchiveWriter.create(
            .emptyFile, named: "notes.txt", inInnerDirectory: "/docs",
            ofArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(try fixture.files() == ["docs/deep.txt", "docs/notes.txt", "one.txt", "two.txt"])
        #expect(try fixture.readBack("docs/notes.txt").isEmpty)
    }

    // MARK: - Refusals leave the archive alone

    /// Each occupant a create could land on: a file under a folder's name, a folder under a file's,
    /// and a twin differing only in case, which the APFS the tree is staged on reads as one name.
    @Test("a name already there is refused, and the archive is byte-identical")
    func refusesAnOccupiedName() throws {
        let fixture = try Fixture()
        let before = try fixture.archiveBytes()

        for (creation, name) in [
            (ArchiveMutation.Creation.folder, "one.txt"),
            (.emptyFile, "docs"),
            (.emptyFile, "TWO.TXT")
        ] {
            #expect(throws: VFSError.self) {
                try ArchiveWriter.create(
                    creation, named: name, inInnerDirectory: "/",
                    ofArchiveAt: fixture.archive, undo: fixture.undo
                )
            }
        }

        // Byte-identical, which is the claim: the refusal happens inside the staged tree, so the
        // container is never repacked, and `two.txt` was never emptied to make a file of its name.
        #expect(try fixture.archiveBytes() == before)
        #expect(try fixture.readBack("two.txt") == "second")
        #expect(fixture.storeIsEmpty(), "a refused create kept a copy to undo from")
    }

    @Test("a name no member can have is refused, and the archive is byte-identical")
    func refusesANameThatIsNotAName() throws {
        let fixture = try Fixture()
        let before = try fixture.archiveBytes()

        for bad in ["", "..", ".", "a/b", "../escape"] {
            #expect(throws: (any Error).self) {
                try ArchiveWriter.create(
                    .folder, named: bad, inInnerDirectory: "/docs",
                    ofArchiveAt: fixture.archive, undo: fixture.undo
                )
            }
        }
        #expect(try fixture.archiveBytes() == before)
    }

    // MARK: - What the rewrite has to preserve

    /// The same claim the delete and rename twins pin: an archive that came back in the clear would
    /// be the quietest possible loss of protection. The new folder going through the libarchive
    /// route is the other half, since that route writes what its walk found rather than packing `.`.
    @Test("an encrypted archive stays encrypted, and the new folder is in it")
    func keepsEncryption() throws {
        let fixture = try Fixture(encryption: .aes256)

        try ArchiveWriter.create(
            .folder, named: "made", inInnerDirectory: "/",
            ofArchiveAt: fixture.archive, passphrase: Fixture.passphrase, undo: fixture.undo
        )

        #expect(try fixture.kind(of: "made") == .directory)
        let inspection = try EncryptedArchiveReader.inspect(archiveAt: fixture.archive)
        let files = inspection.entries.filter { $0.kind != .directory }
        #expect(!files.isEmpty && files.allSatisfy(\.isEncrypted))
        #expect(try fixture.readBack("one.txt") == "first")
    }

    /// `bsdtar -a` takes the format from the suffix, so a create inside a `.tar.gz` must come back a
    /// gzip, which the magic says and the members cannot: a repack that fell back to zip would hold
    /// exactly the right entries (docs/NOTES.md ▸ bsdtar).
    @Test("a .tar.gz stays a .tar.gz")
    func keepsTheContainerFormat() throws {
        let fixture = try Fixture(suffix: "tar.gz")

        try ArchiveWriter.create(
            .emptyFile, named: "added.txt", inInnerDirectory: "/",
            ofArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(try fixture.archiveBytes().prefix(2) == Data([0x1F, 0x8B]))
        #expect(try fixture.files().contains("added.txt"))
    }

    /// ⌘Z has to put the container back, which is what lets F7 inside an archive run without a
    /// confirmation, exactly as F2 does.
    @Test("a create is undoable")
    func isUndoable() throws {
        let fixture = try Fixture()

        let snapshot = try ArchiveWriter.create(
            .folder, named: "made", inInnerDirectory: "/",
            ofArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(snapshot != nil, "the rewrite kept no copy to undo from")
    }

    // MARK: - Fixture

    struct Fixture {
        static let passphrase = ArchivePassphrase("correct horse")

        let directory: URL
        let archive: String
        /// A scratch store, never the app's own (see the suite's doc comment).
        let undo: ArchiveUndoStorage.Request
        private let storeRoot: URL

        /// `one.txt`, `two.txt` and `docs/deep.txt`. A zip is written by the in-process writer, as
        /// rename's fixture is; any other suffix is packed by `bsdtar -a`, so the format comes from
        /// the name exactly as the repack's will.
        init(encryption: ArchiveEncryption = .none, suffix: String = "zip") throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveCreate-\(UUID().uuidString)")
            let source = directory.appendingPathComponent("source", isDirectory: true)
            let docs = source.appendingPathComponent("docs", isDirectory: true)
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            try "first".write(
                to: source.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8
            )
            try "second".write(
                to: source.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8
            )
            try "deep".write(
                to: docs.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8
            )

            storeRoot = directory.appendingPathComponent("undo-store", isDirectory: true)
            undo = ArchiveUndoStorage.Request(store: ArchiveUndoStore(root: storeRoot), live: [])
            archive = directory.appendingPathComponent("fixture.\(suffix)").path

            let names = ["docs", "one.txt", "two.txt"]
            guard suffix == "zip" else {
                try Self.bsdtar(["-a", "-c", "-f", archive, "-C", source.path] + names)
                return
            }
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

        /// Every non-directory member's name, read back through the reader rather than the writer
        /// that produced it, so the two cannot agree about something neither has right.
        func files() throws -> [String] {
            try entries().filter { $0.kind != .directory }.map(\.archivePath).sorted()
        }

        /// What kind of entry `name` is, or `nil` when the archive has none. A directory's stored
        /// name ends in `/` in every format here, and that slash is not part of what the user typed.
        func kind(of name: String) throws -> ArchiveSourceItem.Kind? {
            try entries().first { $0.archivePath == name || $0.archivePath == name + "/" }?.kind
        }

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

        func storeIsEmpty() -> Bool {
            ((try? FileManager.default.contentsOfDirectory(atPath: storeRoot.path)) ?? []).isEmpty
        }

        private func entries() throws -> [EncryptedArchiveReader.Entry] {
            try EncryptedArchiveReader.inspect(archiveAt: archive).entries
        }

        private static func bsdtar(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}

/// Where F7 and ⇧F4 are offered, and that ⇧F4 inside an archive really reaches the archive.
///
/// The gate is the half that was "no" before: a browsed archive has no real directory, so
/// `creationDirectory` is `nil` there and both keys did nothing at all. The narrowness rows (a
/// nested archive, a folder on disk) are what keep "an archive accepts creates" from becoming
/// "every pane does" or "every archive does".
@MainActor
@Suite("Creating inside an archive: reach")
struct ArchiveCreateReachTests {
    private static func pane(at path: VFSPath, host: StubPanelHost? = nil) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.host = host
        pane.panel = Panel(model: DirectoryModel(listing: DirectoryListing(path: path, entries: [])))
        return pane
    }

    private static func newFolderItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.action = #selector(PanelViewController.newFolder(_:))
        return item
    }

    @Test("a top-level archive offers F7 and ⇧F4 in the folder being browsed")
    func aTopLevelArchiveIsOffered() {
        let docs = VFSPath(backend: .archive(forArchiveAt: "/Users/tester/outer.zip"), path: "/docs")
        let pane = Self.pane(at: docs)

        #expect(pane.archiveCreationDirectory == docs)
        #expect(pane.createTarget == docs)
        // The real validator, because a disabled item swallows its own key equivalent: a gate the
        // flow passes and the menu refuses is a dead F7 (docs/NOTES.md ▸ AppKit).
        #expect(pane.validateMenuItem(Self.newFolderItem()))
    }

    /// A nested archive's own bytes are an extracted temp copy, so a rewrite would land somewhere
    /// thrown away. The line F8, paste, F2 and the write-back already draw.
    @Test("a nested archive is not offered either")
    func aNestedArchiveIsRefused() {
        let host = StubPanelHost()
        let extracted = "/tmp/dirnex-nested/inner.zip"
        host.nestedArchiveRegistry.record(
            mountOnDiskPath: extracted,
            origin: VFSPath(
                backend: .archive(forArchiveAt: "/Users/tester/outer.zip"),
                path: "/inner.zip"
            )
        )
        let pane = Self.pane(
            at: VFSPath(backend: .archive(forArchiveAt: extracted), path: "/"),
            host: host
        )

        #expect(pane.archiveCreationDirectory == nil)
        #expect(pane.createTarget == nil)
        #expect(!pane.validateMenuItem(Self.newFolderItem()))
    }

    /// The other direction: a folder on disk keeps the route it always had, through the backend,
    /// and the archive branch says nothing about it.
    @Test("a folder on this Mac keeps its own route")
    func aLocalFolderIsUnchanged() {
        let directory = VFSPath.local(NSTemporaryDirectory())
        let pane = Self.pane(at: directory)

        #expect(pane.archiveCreationDirectory == nil)
        #expect(pane.createTarget == directory)
    }

    /// ⇧F4 through the pane, to the one outcome only the archive's own create can produce.
    ///
    /// `TWO.TXT` is not in the table of contents, which is case-sensitive, so the dialog's `stat`
    /// finds nothing and ⇧F4 goes on to create, through the rewrite. The staged tree is on APFS,
    /// where `two.txt` already holds the name, so the create refuses with "already exists".
    ///
    /// **The detail sentence is the discriminator, not the sheet.** Before this route existed the
    /// same call reached the archive backend's `createFile`, which refuses as unsupported, under the
    /// very same "Can't create “TWO.TXT”" title with one OK button. Only the staged create can say
    /// the name is taken, so the expected detail is built with the pane's own `describe` (which keeps
    /// it language-independent) and compared whole. Driven to a refusal on purpose: a success would
    /// capture into the developer's real undo store (see `ArchiveCreateTests`).
    @Test("⇧F4 with a name the archive refuses reaches the archive and reports it")
    func shiftF4ReachesTheArchive() async throws {
        let fixture = try ArchiveCreateTests.Fixture()
        let root = VFSPath(backend: .archive(forArchiveAt: fixture.archive), path: "/")
        let before = try fixture.archiveBytes()
        let window = TrashlessProbe.window()
        let host = StubPanelHost()
        let pane = Self.pane(at: root, host: host)
        window.contentViewController = pane
        pane.loadViewIfNeeded()

        pane.editFile(named: "TWO.TXT", in: root)

        try await settleUntil(within: .seconds(60)) { window.attachedSheet != nil }
        #expect(sheetButtonCount(in: window) == 1, "expected a lone report, not a question")
        let taken = pane.describe(VFSError.alreadyExists(root.appending("TWO.TXT")))
        #expect(
            sheetText(in: window).contains(taken),
            "the refusal did not come from the staged create"
        )
        #expect(try fixture.archiveBytes() == before)
        window.attachedSheet.map { window.endSheet($0) }
    }
}
