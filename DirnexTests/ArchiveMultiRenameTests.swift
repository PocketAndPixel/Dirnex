import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// ⇧F2 inside a browsed archive: the whole batch as one rewrite (taken 2026-11-05).
///
/// The claims are the batch's own on top of rename's: **every** member takes its new name in a
/// single pass (one undo copy, not one per member), a folder and a file inside it can both be in the
/// batch, and a refusal anywhere leaves the archive byte-identical rather than half renamed.
///
/// The writer is driven with a scratch undo store (`ArchiveCreateTests.Fixture`); the pane only to
/// a refusal, which captures nothing, since a success would file a copy into the developer's own
/// `~/Library/Application Support/Dirnex` (see `ArchiveCreateTests`).
@Suite("Multi-rename inside an archive")
struct ArchiveMultiRenameTests {
    private typealias Fixture = ArchiveCreateTests.Fixture
    private typealias Rename = ArchiveMutation.Rename

    // MARK: - The rewrite

    @Test("every member takes its new name in one rewrite, and keeps its bytes")
    func renamesABatchInOnePass() throws {
        let fixture = try Fixture()

        try ArchiveWriter.rename(
            [
                Rename(innerPath: "/one.txt", newName: "uno.txt"),
                Rename(innerPath: "/two.txt", newName: "dos.txt"),
                Rename(innerPath: "/docs/deep.txt", newName: "hondo.txt")
            ],
            inArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(try fixture.files() == ["docs/hondo.txt", "dos.txt", "uno.txt"])
        #expect(try fixture.readBack("uno.txt") == "first")
        #expect(try fixture.readBack("dos.txt") == "second")
        #expect(try fixture.readBack("docs/hondo.txt") == "deep")
        // One copy for the batch: the container was repacked once, which is the whole point.
        #expect(fixture.storedCopies() == 1)
    }

    /// A tree selection can mark a folder and a file inside it. The file is moved first, inside the
    /// folder's old name, and the folder then carries it; in the order marked, the file's path would
    /// point at nothing once the folder had moved.
    @Test("a folder and a file inside it are renamed together")
    func renamesAFolderAndItsChild() throws {
        let fixture = try Fixture()

        try ArchiveWriter.rename(
            [
                Rename(innerPath: "/docs", newName: "guides"),
                Rename(innerPath: "/docs/deep.txt", newName: "renamed.txt")
            ],
            inArchiveAt: fixture.archive, undo: fixture.undo
        )

        #expect(try fixture.files() == ["guides/renamed.txt", "one.txt", "two.txt"])
        #expect(try fixture.readBack("guides/renamed.txt") == "deep")
    }

    // MARK: - All or nothing

    /// `docs` is not in the batch, so the plan cannot see it; the staged move refuses it. The two
    /// renames before it in the batch had already happened in the staged tree, and none of them
    /// reaches the archive, which is the all-or-nothing claim.
    @Test("a name held outside the batch refuses all of it, byte-identical")
    func refusesTheWholeBatchOnACollision() throws {
        let fixture = try Fixture()
        let before = try fixture.archiveBytes()

        #expect(throws: VFSError.alreadyExists(
            VFSPath(backend: .archive(forArchiveAt: fixture.archive), path: "/docs")
        )) {
            try ArchiveWriter.rename(
                [
                    Rename(innerPath: "/docs/deep.txt", newName: "moved.txt"),
                    Rename(innerPath: "/one.txt", newName: "uno.txt"),
                    Rename(innerPath: "/two.txt", newName: "docs")
                ],
                inArchiveAt: fixture.archive, undo: fixture.undo
            )
        }
        #expect(try fixture.archiveBytes() == before)
        #expect(fixture.storeIsEmpty(), "a refused batch kept a copy to undo from")
    }

    @Test("a swap is refused before the archive is opened")
    func refusesASwap() throws {
        let fixture = try Fixture()
        let before = try fixture.archiveBytes()

        #expect(throws: (any Error).self) {
            try ArchiveWriter.rename(
                [
                    Rename(innerPath: "/one.txt", newName: "two.txt"),
                    Rename(innerPath: "/two.txt", newName: "one.txt")
                ],
                inArchiveAt: fixture.archive, undo: fixture.undo
            )
        }
        #expect(try fixture.archiveBytes() == before)
    }

    // MARK: - What the rewrite has to preserve

    @Test("an encrypted archive stays encrypted")
    func keepsEncryption() throws {
        let fixture = try Fixture(encryption: .aes256)

        try ArchiveWriter.rename(
            [
                Rename(innerPath: "/one.txt", newName: "uno.txt"),
                Rename(innerPath: "/two.txt", newName: "dos.txt")
            ],
            inArchiveAt: fixture.archive,
            passphrase: Fixture.passphrase, undo: fixture.undo
        )

        let inspection = try EncryptedArchiveReader.inspect(archiveAt: fixture.archive)
        let files = inspection.entries.filter { $0.kind != .directory }
        #expect(!files.isEmpty && files.allSatisfy(\.isEncrypted))
        #expect(try fixture.readBack("uno.txt") == "first")
    }
}

/// Where ⇧F2 is offered once archive members are in the set, and that its apply reaches the archive.
@MainActor
@Suite("Multi-rename inside an archive: reach")
struct ArchiveMultiRenameReachTests {
    private static func entry(_ path: VFSPath, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    /// A pane at `path` listing `entries`, every one of them marked.
    private static func pane(
        at path: VFSPath,
        entries: [FileEntry],
        host: StubPanelHost? = nil
    ) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.host = host
        pane.panel = Panel(
            model: DirectoryModel(listing: DirectoryListing(path: path, entries: entries))
        )
        pane.panel.selectAll()
        return pane
    }

    private static func multiRenameItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.action = #selector(PanelViewController.multiRenameSelection(_:))
        return item
    }

    private static let outer = "/Users/tester/outer.zip"

    @Test("a marked set inside one archive goes to that archive")
    func oneArchiveIsOffered() {
        let root = VFSPath(backend: .archive(forArchiveAt: Self.outer), path: "/")
        let pane = Self.pane(at: root, entries: [
            Self.entry(root.appending("a.txt")),
            Self.entry(root.appending("b.txt"))
        ])

        #expect(
            pane.multiRenameRoute(for: pane.selectionTargets()) == .archiveMember(
                archiveOnDiskPath: Self.outer
            )
        )
        #expect(pane.validateMenuItem(Self.multiRenameItem()))
    }

    /// The line every archive write draws: a nested archive's bytes are a temp copy.
    @Test("a nested archive is not offered")
    func aNestedArchiveIsRefused() {
        let host = StubPanelHost()
        let extracted = "/tmp/dirnex-nested/inner.zip"
        host.nestedArchiveRegistry.record(
            mountOnDiskPath: extracted,
            origin: VFSPath(backend: .archive(forArchiveAt: Self.outer), path: "/inner.zip")
        )
        let root = VFSPath(backend: .archive(forArchiveAt: extracted), path: "/")
        let pane = Self.pane(at: root, entries: [Self.entry(root.appending("a.txt"))], host: host)

        #expect(pane.multiRenameRoute(for: pane.selectionTargets()) == .unavailable)
        #expect(!pane.validateMenuItem(Self.multiRenameItem()))
    }

    /// One rewrite covers one archive, and the backend loop cannot rename a member at all, so a set
    /// that spans two archives, or an archive and a folder, has no route that renames all of it.
    @Test("a set across two archives, or an archive and a folder, is refused")
    func mixedSetsAreRefused() {
        let first = VFSPath(backend: .archive(forArchiveAt: Self.outer), path: "/a.txt")
        let second = VFSPath(
            backend: .archive(forArchiveAt: "/Users/tester/other.zip"),
            path: "/b.txt"
        )
        let local = VFSPath.local(NSTemporaryDirectory() + "c.txt")
        let pane = Self.pane(at: .local(NSTemporaryDirectory()), entries: [])

        #expect(pane.multiRenameRoute(for: [Self.entry(first), Self.entry(second)]) == .unavailable)
        #expect(pane.multiRenameRoute(for: [Self.entry(first), Self.entry(local)]) == .unavailable)
    }

    /// The narrowness control: a folder on this Mac keeps the backend loop it always had.
    @Test("a folder on this Mac keeps the backend route")
    func aLocalFolderIsUnchanged() {
        let directory = VFSPath.local(NSTemporaryDirectory())
        let pane = Self.pane(at: directory, entries: [Self.entry(directory.appending("a.txt"))])

        #expect(pane.multiRenameRoute(for: pane.selectionTargets()) == .backend)
    }

    /// The record a rename inside an archive journals carries what the swap does to member names, so
    /// ⌘Z and ⇧⌘Z can move search hits inside the archive (2026-11-05). Through the pane's own
    /// funnel and a stub host that keeps the record; the archive is any readable file, since the
    /// record only reads its size and date.
    @Test("an archive rename journals its renames, reversed for undo")
    func journalCarriesTheRenames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveRenameJournal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("pkg.zip").path
        try Data("zip".utf8).write(to: URL(fileURLWithPath: archive))
        let host = StubPanelHost()
        let root = VFSPath(backend: .archive(forArchiveAt: archive), path: "/")
        let pane = Self.pane(at: root, entries: [], host: host)
        let forward = [
            PathRename(
                from: root.appending("docs").appending("a.txt"),
                to: root.appending("docs").appending("b.txt")
            ),
            PathRename(from: root.appending("docs"), to: root.appending("guides"))
        ]

        pane.journalArchiveRewrite(
            ArchiveUndoSnapshot(
                archive: archive,
                snapshot: directory.appendingPathComponent("copy").path,
                restored: ArchiveUndoWitness(byteSize: 1, modified: Date(timeIntervalSince1970: 0))
            ),
            renamed: forward
        )

        let record = try #require(host.recordedUndo.last)
        // The undo direction; redo's inversion is the core's (`ArchiveUndoRenameTests`).
        #expect(SearchSnapshot.renames(appliedBy: record, report: UndoReport(failures: []))
            == PathRename.reversal(of: forward))
    }

    /// The apply, through the pane, to an outcome only the archive's rewrite can produce.
    ///
    /// The proposal is built by hand with status `.rename` onto a name the archive already holds,
    /// which the planner would have caught, so that only the staged move is left to refuse it. The
    /// backend loop the tool used before would have reached `moveItem` on the archive, which refuses
    /// as unsupported, and reported "the other items were renamed". The detail sentence is built
    /// with the pane's own `describe`, so the comparison holds in any language.
    @Test("the apply reaches the archive, and a refusal there renames nothing")
    func applyReachesTheArchive() async throws {
        let fixture = try ArchiveCreateTests.Fixture()
        let root = VFSPath(backend: .archive(forArchiveAt: fixture.archive), path: "/")
        let before = try fixture.archiveBytes()
        let window = TrashlessProbe.window()
        let host = StubPanelHost()
        let entries = try CompositeBackend(local: LocalBackend()).listDirectory(at: root)
        let pane = Self.pane(at: root, entries: entries, host: host)
        window.contentViewController = pane
        pane.loadViewIfNeeded()
        let one = root.appending("one.txt")

        pane.applyMultiRename(
            [
                RenameProposal(
                    source: one,
                    originalName: "one.txt",
                    newName: "two.txt",
                    status: .rename
                )
            ],
            targets: pane.selectionTargets()
        )

        try await settleUntil(within: .seconds(60)) { window.attachedSheet != nil }
        #expect(sheetButtonCount(in: window) == 1, "expected a lone report, not a question")
        let taken = pane.describe(VFSError.alreadyExists(root.appending("two.txt")))
        #expect(
            sheetText(in: window).contains(taken),
            "the refusal did not come from the staged move"
        )
        #expect(try fixture.archiveBytes() == before)
        window.attachedSheet.map { window.endSheet($0) }
    }
}
