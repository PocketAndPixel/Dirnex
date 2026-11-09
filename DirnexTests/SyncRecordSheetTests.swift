import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The box in the Synchronize window that asks for a record (PLAN.md §M37 Slice 8), and what the
/// window then says about the rows on screen.
@Suite("Sync sheet: the box that keeps versions")
@MainActor
struct SyncRecordBoxTests {
    private static let vault = "/Volumes/Vault"

    @Test("two folders on this Mac can have a record, and a server side, a vault or no store cannot")
    func whichPairs() throws {
        let store = SyncRecordStore(parent: FileManager.default.temporaryDirectory)
        let sftp = VFSPath(
            backend: .sftp(SFTPLocation(host: "example.test", username: "oleg")),
            path: "/srv"
        )
        #expect(
            SyncRecordAccess(
                left: .local("/a"),
                right: .local("/b"),
                store: store,
                vaultMountPoints: []
            ) != nil
        )
        #expect(
            SyncRecordAccess(left: .local("/a"), right: sftp, store: store, vaultMountPoints: []) == nil
        )
        #expect(
            SyncRecordAccess(
                left: .local("/a"),
                right: .local("/b"),
                store: nil,
                vaultMountPoints: []
            ) == nil
        )
        #expect(SyncRecordAccess(
            left: .local("\(Self.vault)/a"),
            right: .local("/b"),
            store: store,
            vaultMountPoints: [Self.vault]
        ) == nil)
    }

    @Test("a pair that cannot have a record has no box, and the window keeps its size")
    func noBox() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        let sheet = try await rig.sheet(withRecords: false)
        #expect(sheet.keepBox.isHidden)
        #expect(sheet.recordChoice == nil)
        #expect(sheet.view.fittingSize.height == 520)
    }

    @Test("the box's row comes out of the window rather than out of the table")
    func windowGrows() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        let sheet = try await rig.sheet()
        #expect(!sheet.keepBox.isHidden)
        #expect(sheet.view.fittingSize.height == 546)
    }

    @Test("the box is off until a pair is remembered, and on once it is", arguments: [false, true])
    func boxFollowsRecord(remembered: Bool) async throws {
        let rig = try SyncRecordRig(remembering: remembered)
        defer { rig.cleanup() }
        let sheet = try await rig.sheet()
        #expect(sheet.rememberedAtOpen == remembered)
        #expect(sheet.keepBox.state == (remembered ? .on : .off))
    }

    @Test("Synchronize keeps with the box on, forgets on unticking, and otherwise does nothing")
    func choices() async throws {
        let unremembered = try SyncRecordRig(remembering: false)
        defer { unremembered.cleanup() }
        let fresh = try await unremembered.sheet()
        #expect(fresh.recordChoice == nil)
        #expect(!fresh.boxDiffersFromRecord)
        fresh.keepBox.state = .on
        #expect(fresh.boxDiffersFromRecord)
        guard case .keep = fresh.recordChoice else {
            Issue.record("a ticked box keeps")
            return
        }

        let remembered = try SyncRecordRig()
        defer { remembered.cleanup() }
        let known = try await remembered.sheet()
        #expect(!known.boxDiffersFromRecord)
        guard case .keep = known.recordChoice else {
            Issue.record("a box left on keeps")
            return
        }
        known.keepBox.state = .off
        #expect(known.boxDiffersFromRecord)
        guard case .forget = known.recordChoice else {
            Issue.record("an unticked box forgets")
            return
        }
    }

    @Test("ticking the box on folders already in sync gives Synchronize something to do")
    func tickOnFoldersInSync() async throws {
        let rig = try SyncRecordRig(remembering: false)
        defer { rig.cleanup() }
        try rig.writeBoth("a.txt", "same\n")
        let sheet = try await rig.sheet()
        #expect(sheet.rows.isEmpty)
        #expect(!sheet.syncButton.isEnabled)

        sheet.keepBox.state = .on
        sheet.keepBoxChanged(sheet.keepBox)
        #expect(sheet.syncButton.isEnabled)

        var applied: [([SyncDirectoriesController.Decision], SyncRecordChoice?)] = []
        sheet.onApply = { applied.append(($0, $1)) }
        sheet.apply(nil)
        #expect(applied.count == 1)
        #expect(applied.first?.0.isEmpty == true)
        guard case .keep = applied.first?.1 else {
            Issue.record("the commit carries the box's choice")
            return
        }
    }

    @Test("a box that says what the record already says leaves Synchronize as it was")
    func nothingToCommit() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.writeBoth("a.txt", "same\n")
        let sheet = try await rig.sheet()
        #expect(!sheet.syncButton.isEnabled)
        var applied = 0
        sheet.onApply = { _, _ in applied += 1 }
        sheet.apply(nil)
        #expect(applied == 0)
    }

    @Test("unticking on rows with nothing checked is still something to commit")
    func untickWithRowsUnchecked() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.writeLeft("a.txt", "only here\n")
        let sheet = try await rig.sheet()
        sheet.rows[0].included = false
        sheet.updateChrome()
        #expect(!sheet.syncButton.isEnabled)

        sheet.keepBox.state = .off
        sheet.keepBoxChanged(sheet.keepBox)
        #expect(sheet.syncButton.isEnabled)
    }
}

@Suite("Sync sheet: a row changed on both sides")
@MainActor
struct SyncRecordRowTests {
    /// The separators in the footer, one per clause after the first.
    private func clauses(_ sheet: SyncDirectoriesController) -> Int {
        sheet.statusLabel.stringValue.components(separatedBy: " · ").count
    }

    private func menu(_ sheet: SyncDirectoriesController, row: Int = 0) -> NSMenu {
        let menu = NSMenu()
        sheet.fill(menu, forRow: row)
        return menu
    }

    @Test("Both Directions leaves it unticked as a conflict and counts it once")
    func bothDirections() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let sheet = try await rig.sheet(directions: [.bidirectional])
        let row = try #require(sheet.rows.first)
        #expect(sheet.isChangedOnBoth(row.entry))
        #expect(row.action == .conflict)
        #expect(!row.included)
        // "0 to copy, 0 to delete" and one clause for this row, and not a second for a conflict.
        #expect(clauses(sheet) == 2)
    }

    @Test(
        "a mirror keeps its copy and still marks the row",
        arguments: [SyncDirection.leftToRight, .rightToLeft]
    )
    func mirror(direction: SyncDirection) async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let sheet = try await rig.sheet(directions: [direction])
        let row = try #require(sheet.rows.first)
        #expect(sheet.isChangedOnBoth(row.entry))
        #expect(row.action == (direction == .leftToRight ? .copyToRight : .copyToLeft))
        #expect(row.included)
        #expect(clauses(sheet) == 2)
    }

    @Test("flipping the direction takes the record into account each way")
    func directionFlip() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let sheet = try await rig.sheet()
        #expect(sheet.direction == .leftToRight)
        #expect(sheet.rows[0].action == .copyToRight)

        sheet.directionControl.selectedSegment = 1
        sheet.directionChanged(sheet.directionControl)
        #expect(sheet.rows[0].action == .conflict)
        #expect(!sheet.rows[0].included)

        sheet.directionControl.selectedSegment = 0
        sheet.directionChanged(sheet.directionControl)
        #expect(sheet.rows[0].action == .copyToRight)
        #expect(sheet.rows[0].included)
    }

    @Test("a file changed on one side is not marked and keeps the direction's default")
    func oneSide() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.writeBoth("a.txt", "kept\n")
        try rig.keep()
        try rig.writeLeft("a.txt", "a longer edit\n")
        try rig.makeLeftNewer("a.txt")
        let sheet = try await rig.sheet(directions: [.bidirectional])
        #expect(!sheet.isChangedOnBoth(sheet.rows[0].entry))
        #expect(sheet.rows[0].action != .conflict)
        #expect(
            menu(sheet).items.allSatisfy { $0.action != #selector(
                SyncDirectoriesController.mergeRow(_:)
            ) }
        )
    }

    @Test("a pair with no record offers no merge")
    func noRecord() async throws {
        let rig = try SyncRecordRig(remembering: false)
        defer { rig.cleanup() }
        try rig.writeLeft("a.txt", "mine\n")
        try rig.writeRight("a.txt", "a longer one\n")
        let sheet = try await rig.sheet(directions: [.bidirectional])
        #expect(sheet.changes.isEmpty)
        #expect(
            menu(sheet).items.allSatisfy { $0.action != #selector(
                SyncDirectoriesController.mergeRow(_:)
            ) }
        )
    }

    @Test("a file with no version kept offers no merge")
    func noVersion() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.writeLeft("a.txt", "mine\n")
        try rig.writeRight("a.txt", "a longer one\n")
        try rig.makeLeftNewer("a.txt")
        let sheet = try await rig.sheet(directions: [.bidirectional])
        #expect(sheet.changes.isEmpty)
        #expect(sheet.rows[0].action == .copyToRight)
    }

    @Test("Merge… comes first on such a row, and hands over the kept version")
    func mergeItem() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let sheet = try await rig.sheet()
        let item = try #require(menu(sheet).items.first)
        #expect(item.action == #selector(SyncDirectoriesController.mergeRow(_:)))

        var requests: [SyncMergeRequest] = []
        sheet.onMerge = { requests.append($0) }
        sheet.mergeRow(item)
        let request = try #require(requests.first)
        #expect(request.relativePath == "a.txt")
        #expect(request.left.path == .local(rig.left.appendingPathComponent("a.txt").path)
            || request.left.name == "a.txt")
        #expect(try String(contentsOf: request.base, encoding: .utf8) == "one\ntwo\nthree\n")
    }

    @Test("a merge needs both sides within 64 MiB, on both sides, and able to take the result")
    func notOffered() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        let sheet = try await rig.sheet()
        let limit = ByteComparator.prescanByteLimit
        sheet.changes = ["a.txt": .changedOnBoth(base: URL(fileURLWithPath: "/base"))]

        #expect(
            sheet.mergeRequest(for: SyncRecordRig.row("a.txt", leftSize: limit, rightSize: limit)) != nil
        )
        #expect(sheet.mergeRequest(for: SyncRecordRig.row("a.txt", leftSize: limit + 1)) == nil)
        #expect(sheet.mergeRequest(for: SyncRecordRig.row("a.txt", rightSize: limit + 1)) == nil)
        #expect(sheet.mergeRequest(for: SyncRecordRig.row("a.txt", hasRight: false)) == nil)
        #expect(sheet.mergeRequest(for: SyncRecordRig.row("b.txt")) == nil)

        let readOnly = try await rig.sheet(directions: [.leftToRight])
        readOnly.changes = sheet.changes
        #expect(readOnly.mergeRequest(for: SyncRecordRig.row("a.txt")) == nil)
    }

    @Test(
        "a row that stops being changed on both sides takes the default again, and others keep theirs"
    )
    func applyChanges() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.writeLeft("a.txt", "mine\n")
        try rig.writeRight("a.txt", "a longer one\n")
        try rig.makeLeftNewer("a.txt")
        try rig.writeLeft("b.txt", "other\n")
        let sheet = try await rig.sheet(directions: [.bidirectional])
        sheet.rows[1].included = false
        let base = URL(fileURLWithPath: "/base")

        sheet.applyChanges(["a.txt": .changedOnBoth(base: base)])
        #expect(sheet.rows[0].action == .conflict)
        #expect(sheet.rows[1].included == false)

        sheet.applyChanges([:])
        #expect(sheet.rows[0].action != .conflict)
        #expect(sheet.rows[1].included == false)
    }

    @Test("a slow read of the record cannot land over a newer one")
    func staleRead() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let sheet = try await rig.sheet()
        let earlier = sheet.changesGeneration
        // A newer read has started, so an answer from the earlier one is dropped.
        sheet.changesGeneration += 1
        sheet.finishReadingChanges([:], generation: earlier)
        #expect(sheet.isChangedOnBoth(sheet.rows[0].entry))

        sheet.finishReadingChanges([:], generation: sheet.changesGeneration)
        #expect(!sheet.isChangedOnBoth(sheet.rows[0].entry))
    }

    @Test("a row answered again after a save keeps its conflict")
    func answeredAgain() async throws {
        let base = URL(fileURLWithPath: "/base")
        let row = SyncRecordRig.row("a.txt")
        let answered = SyncDirectoriesController.rows(
            [SyncDirectoriesController.Row(entry: row.entry, action: .conflict, included: false)],
            replacing: SyncEntry(
                relativePath: "a.txt",
                name: "a.txt",
                left: row.entry.left,
                right: row.entry.right,
                status: .rightNewer
            ),
            direction: .bidirectional,
            change: .changedOnBoth(base: base)
        )
        #expect(answered.first?.action == .conflict)
    }
}

@Suite("Sync: keeping what a sync left equal")
@MainActor
struct SyncRecordKeepingTests {
    private func pane(_ rig: SyncRecordRig) -> (PanelViewController, StubPanelHost) {
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: rig.leftDir,
            restorationKey: nil
        )
        let host = StubPanelHost()
        pane.host = host
        return (pane, host)
    }

    private var finished: Task<Void, Never> { Task {} }

    @Test("the record is kept once the copies have landed, not before")
    func waitsForCopies() async throws {
        let rig = try SyncRecordRig(remembering: false)
        defer { rig.cleanup() }
        try rig.writeLeft("a.txt", "copied\n")
        let (pane, _) = pane(rig)
        let copies = Task {
            try? await Task.sleep(for: .milliseconds(200))
            try? rig.writeRight("a.txt", "copied\n")
        }
        let work = try #require(pane.finishSyncRecord(.keep(rig.records), after: copies, nil))
        await work.value
        #expect(rig.keptText("a.txt") == "copied\n")
    }

    @Test("the record is kept once the deletes have finished, not before")
    func waitsForDeletes() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.writeBoth("a.txt", "doomed\n")
        try rig.keep()
        let (pane, _) = pane(rig)
        let deletes = Task {
            try? await Task.sleep(for: .milliseconds(200))
            try? FileManager.default.removeItem(at: rig.left.appendingPathComponent("a.txt"))
            try? FileManager.default.removeItem(at: rig.right.appendingPathComponent("a.txt"))
        }
        let work = try #require(pane.finishSyncRecord(.keep(rig.records), after: finished, deletes))
        await work.value
        #expect(rig.kept.isEmpty)
    }

    @Test("a first sync starts the record")
    func startsTheRecord() async throws {
        let rig = try SyncRecordRig(remembering: false)
        defer { rig.cleanup() }
        try rig.writeBoth("a.txt", "same\n")
        let (pane, _) = pane(rig)
        let work = try #require(pane.finishSyncRecord(.keep(rig.records), after: finished, nil))
        await work.value
        #expect(rig.store.isRemembered(rig.records.pair))
        #expect(rig.kept.count == 1)
    }

    @Test("forgetting removes the record")
    func forgets() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.writeBoth("a.txt", "same\n")
        try rig.keep()
        let (pane, _) = pane(rig)
        let work = try #require(pane.finishSyncRecord(.forget(rig.records), after: finished, nil))
        await work.value
        #expect(!rig.store.isRemembered(rig.records.pair))
    }

    @Test("a box that was never ticked does nothing at all")
    func nothing() throws {
        let rig = try SyncRecordRig(remembering: false)
        defer { rig.cleanup() }
        let (pane, _) = pane(rig)
        #expect(pane.finishSyncRecord(nil, after: finished, nil) == nil)
        #expect(!rig.store.isRemembered(rig.records.pair))
    }

    @Test("the status line says what keeping came to, and nothing when there is nothing to say")
    func sentences() {
        var report = SyncKeepReport()
        #expect(PanelViewController.keepSentence(.success(report)) == nil)
        report = SyncKeepReport(kept: 3)
        #expect(PanelViewController.keepSentence(.success(report))?.contains("3") == true)
        report = SyncKeepReport(kept: 3, overBudget: 2)
        #expect(PanelViewController.keepSentence(.success(report))?.contains("2") == true)
        #expect(PanelViewController.keepSentence(.failure(CocoaError(.fileWriteUnknown))) != nil)
    }

    @Test("the panel hands the sheet its record and its merge")
    func wiring() throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        let (pane, _) = pane(rig)
        let sheet = pane.makeSyncController(
            leftDir: rig.leftDir,
            rightDir: rig.rightDir,
            directions: SyncRecordRig.allDirections,
            records: rig.records
        )
        #expect(sheet.onMerge != nil)
        #expect(sheet.records?.pair == rig.records.pair)
    }
}
