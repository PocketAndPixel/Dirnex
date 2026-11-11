import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The Synchronize window's record with a server side (PLAN.md §M38 Slice 9): the box, keeping what
/// the sync copied, the row changed on both sides, and Merge… saving into the local file and up to
/// the server.
@Suite("Sync: a record with a server side")
@MainActor
struct SyncServerMergeTests {
    /// Every window a test built, kept for the life of the host (docs/NOTES.md ▸ Testing).
    private static var retained: [MergeWindowController] = []
    private var finished: Task<Void, Never> { Task {} }

    // MARK: - The box and keeping

    @Test("a server folder on either side makes a pair, and two servers make none")
    func pairs() throws {
        let store = SyncRecordStore(parent: FileManager.default.temporaryDirectory)
        let sftp = VFSPath(backend: MemorySyncServer.serverID, path: "/srv")
        let other = VFSPath(
            backend: .sftp(SFTPLocation(host: "other.test", username: "probe")),
            path: "/srv"
        )
        let one = SyncRecordAccess(
            left: .local("/a"),
            right: sftp,
            store: store,
            vaultMountPoints: []
        )
        let swapped = SyncRecordAccess(
            left: sftp,
            right: .local("/a"),
            store: store,
            vaultMountPoints: []
        )
        #expect(one?.pair == swapped?.pair)
        #expect(one?.pair.serverFolder == sftp)
        #expect(
            SyncRecordAccess(left: other, right: sftp, store: store, vaultMountPoints: []) == nil
        )
    }

    @Test("the box is offered beside a server folder, with a tooltip of its own")
    func box() async throws {
        let rig = try SyncServerRecordRig()
        defer { rig.cleanup() }
        let sheet = try await rig.sheet()
        #expect(!sheet.keepBox.isHidden)
        #expect(sheet.keepBox.state == .on)

        let local = try SyncRecordRig()
        defer { local.cleanup() }
        let localSheet = try await local.sheet()
        #expect(sheet.keepBox.toolTip != nil)
        #expect(sheet.keepBox.toolTip != localSheet.keepBox.toolTip)
    }

    @Test(
        "a sync keeps the file it uploaded, from the rows it ran, and reads nothing from the server"
    )
    func keepsAfterSync() async throws {
        let rig = try SyncServerRecordRig()
        defer { rig.cleanup() }
        try rig.writeLocal("a.txt", "one\n")
        let decisions = try rig.upload("a.txt")

        let work = try #require(rig.pane().finishSyncRecord(
            .keep(rig.records),
            decisions: decisions,
            after: finished,
            nil
        ))
        await work.value

        #expect(rig.keptText("a.txt") == "one\n")
        #expect(rig.kept["a.txt"]?.serverRevision
            == RemoteFileRevision(try rig.server.stat(at: rig.server.path(rig.serverPath("a.txt")))))
        #expect(rig.server.byteReads == 0)
    }

    @Test("Synchronize hands the rows it ran to the record, which keeps what they copied")
    func applyHandsOverTheRows() async throws {
        let rig = try SyncServerRecordRig()
        defer { rig.cleanup() }
        try rig.writeLocal("a.txt", "one\n")
        let pane = rig.pane()
        let sheet = pane.makeSyncController(
            leftDir: rig.leftDir,
            rightDir: rig.rightDir,
            directions: SyncRecordRig.allDirections,
            records: rig.records
        )
        // The rows as the window listed them, then the upload the queue makes of them, which the
        // stub host only records.
        let decisions = try rig.rows().map { SyncDecision(entry: $0, action: .copyToRight) }
        rig.server.put(rig.serverPath("a.txt"), "one\n")

        sheet.onApply?(decisions, .keep(rig.records))

        try await settleUntil(within: .seconds(60)) { rig.keptText("a.txt") != nil }
        #expect(rig.keptText("a.txt") == "one\n")
        #expect((pane.host as? StubPanelHost)?.enqueued.count == 1)
    }

    @Test("a sync handed no rows keeps nothing on a server pair")
    func nothingRun() async throws {
        let rig = try SyncServerRecordRig()
        defer { rig.cleanup() }
        try rig.writeLocal("a.txt", "one\n")
        _ = try rig.upload("a.txt")

        let work = try #require(
            rig.pane().finishSyncRecord(.keep(rig.records), after: finished, nil)
        )
        await work.value

        #expect(rig.kept.isEmpty)
    }

    @Test(
        "a file changed on both sides is marked and offers Merge…, the local side written first",
        arguments: [false, true]
    )
    func marked(serverOnLeft: Bool) async throws {
        let rig = try SyncServerRecordRig(serverOnLeft: serverOnLeft)
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let sheet = try await rig.sheet()

        let row = try #require(sheet.rows.first { $0.entry.relativePath == "a.txt" })
        #expect(sheet.isChangedOnBoth(row.entry))
        let request = try #require(sheet.mergeRequest(for: row))
        #expect(request.server?.path == rig.server.path(rig.serverPath("a.txt")))
        #expect(request.local.path == .local(rig.local.appendingPathComponent("a.txt").path))
        #expect(rig.server.byteReads == 0)
    }

    // MARK: - Merge…

    /// A row's merge, its window, and a copy of the server's file as Merge… brings it down.
    private struct Opened {
        let request: SyncMergeRequest
        let sheet: SyncDirectoriesController
        let copy: URL
    }

    /// The row's merge, and a copy of the server's file as Merge… brings it down.
    private func request(_ rig: SyncServerRecordRig) async throws -> Opened {
        try rig.changeOnBothSides()
        let sheet = try await rig.sheet()
        let row = try #require(sheet.rows.first)
        let request = try #require(sheet.mergeRequest(for: row))
        let copy = rig.root.appendingPathComponent("fetched-a.txt")
        try rig.server.copyFile(
            at: rig.server.path(rig.serverPath("a.txt")),
            to: .local(copy.path),
            progress: { _ in },
            isCancelled: { false }
        )
        return Opened(request: request, sheet: sheet, copy: copy)
    }

    @Test(
        "the versions are read from the local file and the server's copy, each in its pane",
        arguments: [false, true]
    )
    func reads(serverOnLeft: Bool) async throws {
        let rig = try SyncServerRecordRig(serverOnLeft: serverOnLeft)
        defer { rig.cleanup() }
        let opened = try await request(rig)
        let (request, copy) = (opened.request, opened.copy)

        let input = try PanelViewController.readSyncMerge(
            request,
            serverCopy: copy,
            serverDetail: "server.test:/srv/notes/a.txt"
        ).get()

        #expect(input.target.path == rig.local.appendingPathComponent("a.txt").path)
        #expect(input.secondTarget?.path == copy.path)
        #expect(!input.secondTargetKeepsUndo)
        #expect(TextMergeTestsText.text(input.base.document) == "one\ntwo\nthree\n")
        let (server, local) = serverOnLeft ? (input.yours, input.theirs) : (
            input.theirs,
            input.yours
        )
        #expect(TextMergeTestsText.text(server.document) == "one\ntwo\nTHREE!\n")
        #expect(TextMergeTestsText.text(local.document) == "ONE\ntwo\nthree\n")
        #expect(server.detail == "server.test:/srv/notes/a.txt")
        #expect(local.detail.hasSuffix("/local/a.txt"))
    }

    @Test(
        "Save writes the local file with its undo and the copy without, carries the copy up, and keeps the merge"
    )
    func saves() async throws {
        let rig = try SyncServerRecordRig()
        defer { rig.cleanup() }
        let opened = try await request(rig)
        let (request, sheet, copy) = (opened.request, opened.sheet, opened.copy)
        let input = try PanelViewController.readSyncMerge(request, serverCopy: copy).get()
        var carried: [URL] = []
        let edit = EditedFile(
            destination: .remoteFile(rig.server.path(rig.serverPath("a.txt"))),
            temporaryURL: copy,
            name: "a.txt"
        )
        let carry = rig.pane().syncMergeSaving(request, carrying: edit, in: sheet) { edit, _ in
            carried.append(edit.temporaryURL)
            guard let data = try? Data(contentsOf: edit.temporaryURL) else { return false }
            rig.server.put(rig.serverPath("a.txt"), data: data)
            return true
        }.carry
        let journal = CompareSaveRig.JournalBox()
        let controller = window(input, rig: rig, journal: journal, carry: carry)

        #expect(controller.merge?.isResolved == true)
        #expect(await controller.saveResult())

        let merged = "ONE\ntwo\nTHREE!\n"
        #expect(rig.readLocal("a.txt") == merged)
        #expect((try? String(contentsOf: copy, encoding: .utf8)) == merged)
        #expect(carried == [copy])
        #expect(rig.server.text(rig.serverPath("a.txt")) == merged)
        #expect(journal.records.count == 1)
        #expect(rig.keptText("a.txt") == merged)
        #expect(rig.kept["a.txt"]?.serverRevision
            == RemoteFileRevision(try rig.server.stat(at: rig.server.path(rig.serverPath("a.txt")))))
        try await settleUntil(within: .seconds(60)) { sheet.rows.isEmpty }
    }

    @Test("an upload that did not land keeps the version the sync copied")
    func notLanded() async throws {
        let rig = try SyncServerRecordRig()
        defer { rig.cleanup() }
        let opened = try await request(rig)
        let (request, sheet, copy) = (opened.request, opened.sheet, opened.copy)
        let input = try PanelViewController.readSyncMerge(request, serverCopy: copy).get()
        let edit = EditedFile(
            destination: .remoteFile(rig.server.path(rig.serverPath("a.txt"))),
            temporaryURL: copy,
            name: "a.txt"
        )
        let carry = rig.pane().syncMergeSaving(request, carrying: edit, in: sheet) { _, _ in false }.carry
        let controller = window(input, rig: rig, journal: CompareSaveRig.JournalBox(), carry: carry)

        #expect(await controller.saveResult())

        #expect(rig.readLocal("a.txt") == "ONE\ntwo\nTHREE!\n")
        #expect(rig.server.text(rig.serverPath("a.txt")) == "one\ntwo\nTHREE!\n")
        #expect(rig.keptText("a.txt") == "one\ntwo\nthree\n")
    }

    /// A merge window on `input` whose saves keep undo in the rig's own store and journal.
    private func window(
        _ input: MergeInput,
        rig: SyncServerRecordRig,
        journal: CompareSaveRig.JournalBox,
        carry: (@MainActor (NSWindow?) async -> Void)?
    ) -> MergeWindowController {
        let store = ArchiveUndoStore(
            root: rig.root.appendingPathComponent("undo", isDirectory: true)
        )
        let controller = MergeWindowController(
            input: input,
            saving: MergeSaving(
                undo: { ArchiveUndoStorage.Request(store: store, live: []) },
                journal: { journal.records.append($0) },
                carry: carry
            )
        )
        let merge = TextMerge(
            base: input.base.document,
            yours: input.yours.document,
            theirs: input.theirs.document
        )
        controller.load(
            merge,
            prepared: MergePrepared.prepare(
                merge,
                language: nil,
                coloringLimit: CompareTextStyle.syntaxColoringLimit
            )
        )
        Self.retained.append(controller)
        return controller
    }
}
