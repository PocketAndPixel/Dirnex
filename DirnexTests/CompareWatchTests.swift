import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The compare window watching its two files (PLAN.md §M33 Slice 5): a file saved elsewhere is
/// read again and compared again, its own copies leave Edit ▸ Undo and the other file's stay, a side
/// holding unsaved copies asks first, and the window's own save is not mistaken for someone else's.
/// The streams are real FSEvents streams on the rig's files.
@Suite("Compare window file watch")
@MainActor
struct CompareWatchTests {
    /// What the Synchronize window would hear.
    @MainActor
    private final class Heard {
        var origins: [VFSPath] = []
    }

    private func watching(_ rig: CompareSaveRig) -> CompareSaveRig {
        rig.controller.startWatchingFiles()
        return rig
    }

    private func text(_ source: CompareSource) -> String {
        source.document.text(ofFirstLines: .max)
    }

    /// Write `text` over the file in place, as most editors that are not document-based save.
    private func writeInPlace(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// Write `text` beside the file and rename it over, as vim's and NSDocument's saves do.
    private func writeAtomically(_ text: String, to path: String) throws {
        let sibling = path + ".saving"
        try Data(text.utf8).write(to: URL(fileURLWithPath: sibling))
        #expect(rename(sibling, path) == 0)
    }

    /// Wait until the file on `side` shows `expected` and the pair has been compared as it stands.
    ///
    /// 60 s, not the house 30: it is the first wait in most of these tests, so in a full run it
    /// sits in the main-actor stall at the run's start. Measured 2026-10-26: 22–27 s in a green full
    /// run, and past 30 in each of five slower ones (docs/NOTES.md ▸ Testing).
    private func shows(
        _ expected: String,
        on side: ComparisonPaneText.Side,
        in rig: CompareSaveRig
    ) async throws {
        try await settleUntil(within: .seconds(60)) {
            text(rig.controller.source(on: side)) == expected
                && rig.controller.comparedRevision == rig.controller.sidesRevision
        }
    }

    @Test("a file written in place is read again, and the pair compared again")
    func writeInPlaceIsShown() async throws {
        let rig = try watching(CompareSaveRig("a\nB\nc\n", "a\nb\nc\n"))
        defer { rig.cleanup() }
        #expect(rig.controller.fileWatch.watchers.count == 2)

        try writeInPlace("a\nb\nc\nd\n", to: rig.leftPath)
        try await shows("a\nb\nc\nd\n", on: .left, in: rig)
        #expect(rig.controller.comparison?.changeRows.count == 1, "only the added line differs")
        #expect(rig.controller.left.target == .reading(rig.leftPath))
        #expect(rig.controller.window?.isDocumentEdited == false)
        #expect(rig.controller.currentChange == 0, "a change stays current, so the keys still copy")
    }

    @Test("a file saved by renaming another over it is read again too")
    func atomicSaveIsShown() async throws {
        let rig = try watching(CompareSaveRig("a\nB\nc\n", "a\nb\nc\n"))
        defer { rig.cleanup() }
        try writeAtomically("a\nB\nc\n", to: rig.rightPath)
        try await shows("a\nB\nc\n", on: .right, in: rig)
        #expect(rig.controller.comparison?.diff.isIdentical == true)
    }

    @Test("a file read again drops its own copies from Edit ▸ Undo and keeps the other file's")
    func readAgainDropsOnlyItsOwnUndo() async throws {
        let rig = try watching(CompareSaveRig("a\nB\nc\nD\ne\n", "a\nb\nc\nd\ne\n"))
        defer { rig.cleanup() }
        try await rig.copy(to: .left)
        try await rig.copy(to: .right)
        #expect(await rig.controller.saveEditedSides())
        #expect(rig.controller.edits.undoMenuItemTitle == "Undo Copy to Right")

        try writeInPlace("a\nb\nc\nD\ne\nf\n", to: rig.rightPath)
        try await shows("a\nb\nc\nD\ne\nf\n", on: .right, in: rig)
        #expect(
            rig.controller.edits.undoMenuItemTitle == "Undo Copy to Left",
            "the right file's copy named its old lines, and is gone"
        )
        rig.controller.edits.undo()
        try await shows("a\nB\nc\nD\ne\n", on: .left, in: rig)
        #expect(!rig.controller.edits.canUndo, "nothing of the right file's is left to undo")
        #expect(text(rig.controller.right) == "a\nb\nc\nD\ne\nf\n")
    }

    @Test("the window's own save is not read back, so its copies stay undoable")
    func ownSaveIsNotAChange() async throws {
        let rig = try watching(CompareSaveRig("a\nB\nc\n", "a\nb\nc\n"))
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        #expect(rig.controller.handleKey(CompareSaveRig.commandS))
        try await settleUntil { rig.controller.window?.isDocumentEdited == false }

        // The left file's change, made after the save and read back here, has been delivered, so
        // the save's own event, earlier on the same path, has been looked at as well.
        try writeInPlace("a\nB\nc\nd\n", to: rig.leftPath)
        try await shows("a\nB\nc\nd\n", on: .left, in: rig)
        #expect(rig.controller.edits.undoMenuItemTitle == "Undo Copy to Right")
        #expect(rig.controller.window?.attachedSheet == nil)
    }

    @Test("a change under unsaved copies asks, and keeping them leaves ⌘S to ask Save Anyway")
    func keepCopiedChanges() async throws {
        let rig = try watching(CompareSaveRig("a\nB\nc\n", "a\nb\nc\n"))
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        try writeInPlace("the editor's save\n", to: rig.rightPath)

        let sheet = try await rig.sheet()
        let texts = CompareSaveRig.texts(in: sheet.contentView)
        #expect(texts.contains("“right.txt” has changed since this window read it."))
        let buttons = CompareSaveRig.buttons(in: sheet.contentView).map(\.title)
        #expect(buttons.contains("Read Again") && buttons.contains("Keep Copied Changes"))
        try await rig.answer(.alertSecondButtonReturn)
        try await settleUntil {
            rig.controller.window?.attachedSheet == nil && rig.controller.fileWatch.busy.isEmpty
        }
        #expect(text(rig.controller.right) == "a\nB\nc\n")
        #expect(rig.controller.unsavedSides == [.right])

        // The same state of the file is not asked about twice.
        rig.controller.fileMayHaveChanged(rig.controller.right.id)
        #expect(rig.controller.fileWatch.busy.isEmpty)

        let saving = Task { await rig.controller.saveEditedSides() }
        let asked = try await rig.sheet()
        #expect(CompareSaveRig.buttons(in: asked.contentView).map(\.title).contains("Save Anyway"))
        try await rig.answer(.alertSecondButtonReturn)
        #expect(await saving.value == false)
        #expect(rig.contents(rig.rightPath) == "the editor's save\n")
    }

    @Test("Read Again drops the unsaved copies and shows the file as it is")
    func readAgainDropsCopies() async throws {
        let rig = try watching(CompareSaveRig("a\nB\nc\n", "a\nb\nc\n"))
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        try writeInPlace("the editor's save\n", to: rig.rightPath)
        try await rig.answer(.alertFirstButtonReturn)
        try await shows("the editor's save\n", on: .right, in: rig)
        #expect(rig.controller.unsavedSides.isEmpty)
        #expect(!rig.controller.edits.canUndo)
        #expect(rig.controller.window?.isDocumentEdited == false)
    }

    @Test("a local file's change tells the Synchronize window, and a server copy's does not")
    func localChangeIsAnnounced() async throws {
        // Its own server path, since every test's saves post to the one notification center.
        let server = VFSPath(backend: Handoff.remoteID, path: "/srv/\(UUID().uuidString).txt")
        let rig = try watching(CompareSaveRig(
            Data("a\nB\nc\n".utf8),
            Data("a\nb\nc\n".utf8),
            rightOrigin: server,
            rightWriteBack: .remoteFile(server)
        ))
        defer { rig.cleanup() }
        let heard = Heard()
        let observer = NotificationCenter.default.addObserver(
            forName: CompareWindowController.fileSaved,
            object: nil,
            queue: nil
        ) { notification in
            // Posted on the main thread, and delivered on the thread that posts it.
            guard let origin = CompareWindowController.savedOrigin(in: notification),
                  [server, .local(rig.leftPath)].contains(origin) else { return }
            MainActor.assumeIsolated { heard.origins.append(origin) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try writeInPlace("a\nB\nc\n", to: rig.rightPath)
        try await shows("a\nB\nc\n", on: .right, in: rig)
        #expect(heard.origins.isEmpty, "the server has not changed until a write-back lands")

        try writeInPlace("a\nb\nc\n", to: rig.leftPath)
        try await shows("a\nb\nc\n", on: .left, in: rig)
        #expect(heard.origins == [.local(rig.leftPath)])
    }

    @Test("after Swap Sides, a file's change is read into the side it is on now")
    func changeAfterSwap() async throws {
        let rig = try watching(CompareSaveRig("a\nB\nc\n", "a\nb\nc\n"))
        defer { rig.cleanup() }
        rig.controller.swapSides()
        try await settleUntil { rig.controller.comparedRevision == rig.controller.sidesRevision }
        try writeInPlace("a\nb\nc\nd\n", to: rig.rightPath)
        try await shows("a\nb\nc\nd\n", on: .left, in: rig)
        #expect(rig.controller.left.name == "right.txt")
        #expect(text(rig.controller.right) == "a\nB\nc\n")
    }

    @Test("a file that can no longer be read as text is reported, and still shown as it was")
    func unreadableAgain() async throws {
        let rig = try watching(CompareSaveRig("a\nB\nc\n", "a\nb\nc\n"))
        defer { rig.cleanup() }
        try Data([0x61, 0, 0, 0x62, 0, 0xFF, 0]).write(to: URL(fileURLWithPath: rig.leftPath))
        // Like shows(), this first wait includes the full run's main-actor delays. Measured
        // 2026-10-28: the event arrived in 11 ms, but the alert was not presented until 34 s.
        let sheet = try await rig.sheet(within: .seconds(60))
        let texts = CompareSaveRig.texts(in: sheet.contentView)
        #expect(texts.contains("Couldn’t compare these files"))
        #expect(texts.contains("“left.txt” isn’t a text file. Dirnex compares text files only."))
        try await rig.answer(.alertFirstButtonReturn)
        try await settleUntil { rig.controller.fileWatch.busy.isEmpty }
        #expect(text(rig.controller.left) == "a\nB\nc\n")
    }

    @Test("closing the window stops watching")
    func closeStopsWatching() throws {
        let rig = try watching(CompareSaveRig("a\nB\nc\n", "a\nb\nc\n"))
        defer { rig.cleanup() }
        #expect(rig.controller.fileWatch.watchers.count == 2)
        rig.controller.window?.close()
        #expect(rig.controller.fileWatch.watchers.isEmpty)
    }

    @Test("the change made current after a read again is the first at or below the top line")
    func changeAtOrBelowTheTop() throws {
        let left = try ComparedDocument.decode(Data("0\n1\nX\n3\n4\n5\n6\nY\n8\n9\n".utf8))
        let right = try ComparedDocument.decode(Data("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n".utf8))
        let comparison = TextComparison(left, right, options: LineDiffOptions())
        typealias Kept = CompareWindowController.KeptLine
        let change = CompareWindowController.change(atOrBelow:in:)
        #expect(change(Kept(side: .left, line: 2), comparison) == 0, "the change at the top")
        #expect(change(Kept(side: .right, line: 5), comparison) == 1)
        #expect(change(Kept(side: .left, line: 9), comparison) == 1, "none below: the last")
        #expect(change(nil, comparison) == 0)
    }
}
