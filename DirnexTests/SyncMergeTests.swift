import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Merge… on a Synchronize row (PLAN.md §M37 Slice 8): three versions read, and one result saved
/// into both folders.
@Suite("Sync: merging a file changed on both sides")
@MainActor
struct SyncMergeTests {
    /// Every window a test built, kept for the life of the host (docs/NOTES.md ▸ Testing).
    private static var retained: [MergeWindowController] = []

    private func request(_ rig: SyncRecordRig, _ sheet: SyncDirectoriesController) throws -> SyncMergeRequest {
        let row = try #require(sheet.rows.first)
        return try #require(sheet.mergeRequest(for: row))
    }

    private func window(
        _ input: MergeInput,
        store: ArchiveUndoStore? = nil,
        journal: CompareSaveRig.JournalBox = CompareSaveRig.JournalBox(),
        carry: (@MainActor (NSWindow?) async -> Void)? = nil
    ) -> MergeWindowController {
        let controller = MergeWindowController(
            input: input,
            saving: MergeSaving(
                undo: {
                    ArchiveUndoStorage.Request(
                        store: store,
                        live: journal.records.flatMap(SyncMergeTests.snapshots)
                    )
                },
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

    /// Save, giving each of `answers` to the question it meets, and fail by name on any other.
    /// Awaiting the save directly would wait for an answer nobody gives, until the run is killed.
    private func save(
        _ controller: MergeWindowController,
        answering answers: [NSApplication.ModalResponse] = [],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Bool {
        final class Flag {
            var finished = false
        }
        let flag = Flag()
        let host = try #require(controller.window, sourceLocation: sourceLocation)
        let saving = Task {
            defer { flag.finished = true }
            return await controller.saveResult()
        }
        var remaining = answers
        while true {
            try await settleUntil(within: .seconds(60)) { flag.finished || host.attachedSheet != nil }
            guard !flag.finished, let sheet = host.attachedSheet else { break }
            if remaining.isEmpty {
                Issue.record(
                    "the save asked a question this test did not expect",
                    sourceLocation: sourceLocation
                )
                host.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            } else {
                host.endSheet(sheet, returnCode: remaining.removeFirst())
            }
            try await settleUntil(within: .seconds(60)) { flag.finished || host.attachedSheet !== sheet }
        }
        #expect(
            remaining.isEmpty,
            "a question this test expected was not asked",
            sourceLocation: sourceLocation
        )
        return await saving.value
    }

    private static func snapshots(of record: UndoRecord) -> [String] {
        record.steps.compactMap { step in
            guard case let .restoreSavedFile(_, snapshot, _, _) = step else { return nil }
            return snapshot.path
        }
    }

    /// A window over the rig's folders, and what its first row's merge read.
    private struct Opened {
        let input: MergeInput
        let request: SyncMergeRequest
        let sheet: SyncDirectoriesController
    }

    private func opened(_ rig: SyncRecordRig) async throws -> Opened {
        let sheet = try await rig.sheet()
        let request = try request(rig, sheet)
        return try Opened(
            input: PanelViewController.readSyncMerge(request).get(),
            request: request,
            sheet: sheet
        )
    }

    @Test("the left file is Yours, the right is Theirs, and both are saved to")
    func readsTheVersions() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let input = try await opened(rig).input

        #expect(input.name == "a.txt")
        #expect(TextMergeTestsText.text(input.base.document) == "one\ntwo\nthree\n")
        #expect(TextMergeTestsText.text(input.yours.document) == "ONE\ntwo\nthree\n")
        #expect(TextMergeTestsText.text(input.theirs.document) == "one\ntwo\nTHREE!\n")
        #expect(input.target.path.hasSuffix("/left/a.txt"))
        #expect(input.secondTarget?.path.hasSuffix("/right/a.txt") == true)
        #expect(input.yours.detail.hasSuffix("/left/a.txt"))
        #expect(input.theirs.detail.hasSuffix("/right/a.txt"))
    }

    @Test("a side that is not text is refused by name")
    func refusesBinary() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let sheet = try await rig.sheet()
        let request = try request(rig, sheet)
        try rig.writeRight("a.txt", "bi\0nary")
        #expect(throws: CompareReadFailure(name: "a.txt", reason: .binary)) {
            try PanelViewController.readSyncMerge(request).get()
        }
    }

    @Test("Save writes the one result into both files")
    func savesBoth() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let input = try await opened(rig).input
        let controller = window(input)

        #expect(controller.merge?.isResolved == true)
        #expect(try await save(controller))
        #expect(rig.readLeft("a.txt") == "ONE\ntwo\nTHREE!\n")
        #expect(rig.readRight("a.txt") == "ONE\ntwo\nTHREE!\n")
        #expect(!controller.hasUnsavedResult)
        // The same date to the nanosecond, as a copy has, or Size & Date can go on listing the row.
        let (left, right) = (
            rig.left.appendingPathComponent("a.txt"),
            rig.right.appendingPathComponent("a.txt")
        )
        #expect(
            ArchiveUndoWitness.current(ofFileAt: left.path) == ArchiveUndoWitness.current(
                ofFileAt: right.path
            )
        )
    }

    @Test("a second save checks each file against what the first left")
    func savesAgain() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.writeBoth("a.txt", "a\n")
        try rig.keep()
        try rig.writeLeft("a.txt", "L\n")
        try rig.writeRight("a.txt", "RR\n")
        let input = try await opened(rig).input
        let controller = window(input)
        controller.take(.yours)
        try await settleUntil(within: .seconds(60)) { controller.shownChoices == controller.choicesMade }
        #expect(try await save(controller))
        #expect(rig.readRight("a.txt") == "L\n")

        controller.take(.theirs)
        try await settleUntil(within: .seconds(60)) { controller.shownChoices == controller.choicesMade }
        #expect(try await save(controller))
        #expect(rig.readLeft("a.txt") == "RR\n")
        #expect(rig.readRight("a.txt") == "RR\n")
    }

    @Test(
        "a second file changed since it was read asks, and the result stays unsaved until it is written"
    )
    func secondFileChanged() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let input = try await opened(rig).input
        let controller = window(input)
        try rig.writeRight("a.txt", "someone else's longer edit\n")

        #expect(try await save(controller, answering: [.alertSecondButtonReturn]) == false)
        #expect(rig.readLeft("a.txt") == "ONE\ntwo\nTHREE!\n")
        #expect(rig.readRight("a.txt") == "someone else's longer edit\n")
        #expect(controller.hasUnsavedResult)

        #expect(try await save(controller, answering: [.alertFirstButtonReturn]))
        #expect(rig.readRight("a.txt") == "ONE\ntwo\nTHREE!\n")
        #expect(!controller.hasUnsavedResult)
    }

    @Test("each file's old bytes stay in the undo store, one record each")
    func undoKeepsBoth() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let input = try await opened(rig).input
        let store = ArchiveUndoStore(
            root: rig.root.appendingPathComponent("undo", isDirectory: true)
        )
        let journal = CompareSaveRig.JournalBox()
        let controller = window(input, store: store, journal: journal)

        #expect(try await save(controller))
        #expect(journal.records.count == 2)
        let snapshots = journal.records.flatMap(Self.snapshots)
        #expect(snapshots.count == 2)
        for snapshot in snapshots {
            #expect(FileManager.default.fileExists(atPath: snapshot))
        }
    }

    @Test("a saved merge becomes what the pair last agreed on, and the row leaves the list")
    func carry() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let merge = try await opened(rig)
        let (input, request, sheet) = (merge.input, merge.request, merge.sheet)
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: rig.leftDir,
            restorationKey: nil
        )
        let carry = try #require(pane.syncMergeSaving(request, in: sheet).carry)
        let controller = window(input, carry: carry)

        #expect(try await save(controller))
        #expect(rig.keptText("a.txt") == "ONE\ntwo\nTHREE!\n")
        try await settleUntil(within: .seconds(60)) { sheet.rows.isEmpty }
        try await settleUntil(within: .seconds(60)) { !sheet.isReadingChanges }
        #expect(sheet.changes.isEmpty)
    }

    @Test("Merge… opens the window on what it read")
    func opens() async throws {
        let rig = try SyncRecordRig()
        defer { rig.cleanup() }
        try rig.changeOnBothSides()
        let sheet = try await rig.sheet()
        let request = try request(rig, sheet)
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: rig.leftDir,
            restorationKey: nil
        )
        var opened: [MergeInput] = []
        pane.mergeSyncRow(request, in: sheet) { input, saving in
            opened.append(input)
            let controller = MergeWindowController(input: input, saving: saving)
            Self.retained.append(controller)
            return controller
        }
        try await settleUntil(within: .seconds(60)) { !opened.isEmpty }
        #expect(opened.first?.secondTarget?.path.hasSuffix("/right/a.txt") == true)
    }
}

/// The text of a document, as the core's test suite spells it.
enum TextMergeTestsText {
    static func text(_ document: ComparedDocument) -> String {
        document.lines.map { String($0.content) + $0.terminator.text }.joined()
    }
}
