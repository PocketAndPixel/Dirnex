import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Choosing for a conflict in the merge window (PLAN.md §M34 Slice 3). What a choice puts in the
/// result is `DirnexCore`'s and tested there; these pin the window's half: the four take keys and
/// buttons, going on to the next open conflict, and the window's undo under Edit ▸ Undo.
@Suite("Merge window takes")
@MainActor
struct MergeTakeTests {
    @Test("⌥⌘→ takes yours, shows the result, and goes on to the next open conflict")
    func takeYoursByKey() async throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let controller = rig.controller
        #expect(controller.handleKey(MergeRig.takeYours))
        try await rig.landed()
        #expect(controller.resultPane.textView.string == "a\nY\nc\nd\nE\nf\nG\nh\n\nj\n")
        #expect(controller.merge?.choices == [.yours, nil])
        #expect(controller.currentConflict == 1)
        #expect(controller.toolbar.counter.stringValue == "Conflict 2 of 2")
        #expect(controller.banner.stringValue.hasPrefix("1 conflict is still open."))
        #expect(controller.shown?.markKinds == [.resolved, .change, .change, .conflict])
        #expect(controller.shown?.panes[.result]?.fills[1] == .resolved)
        #expect(controller.window?.isDocumentEdited == true)
        #expect(!controller.toolbar.save.isEnabled)
    }

    @Test("⇧⌥⌘← takes both, theirs first, on rows added below the conflict, and Save comes on")
    func takeBothByKey() async throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let controller = rig.controller
        #expect(controller.handleKey(MergeRig.takeTheirs))
        try await rig.landed()
        #expect(controller.currentConflict == 1)
        #expect(controller.handleKey(MergeRig.takeTheirsFirst))
        try await rig.landed()
        #expect(controller.resultPane.textView.string == "a\nT\nc\nd\nE\nf\nG\nh\nK\nI\nj\n")
        #expect(controller.yoursPane.textView.string == "a\nY\nc\nd\nE\nf\ng\nh\nI\n\nj\n")
        #expect(controller.merge?.isResolved == true)
        #expect(controller.currentConflict == 1, "no conflict is open: it stays where it was")
        #expect(controller.banner.isHidden)
        #expect(controller.toolbar.save.isEnabled)

        // ⇧⌥⌘→ is the other order, on the same conflict.
        #expect(controller.handleKey(MergeRig.takeYoursFirst))
        try await rig.landed()
        #expect(controller.resultPane.textView.string == "a\nT\nc\nd\nE\nf\nG\nh\nI\nK\nj\n")
    }

    /// Press one segment the way VoiceOver does: a momentary control keeps no selection set from
    /// code (docs/NOTES.md ▸ Windows).
    private func press(segment: Int, of control: NSSegmentedControl) throws {
        let cell = try #require(control.accessibilityChildren()?.first as? NSObject)
        let segments = try #require(cell.value(forKey: "accessibilityChildren") as? [NSObject])
        try #require(segments.count > segment)
        _ = segments[segment].perform(#selector(NSAccessibilityElement.accessibilityPerformPress))
    }

    @Test("each take button makes its choice, in the order the toolbar draws them")
    func takeButtons() async throws {
        #expect(MergeToolbar.takeChoices == [.yours, .yoursThenTheirs, .theirsThenYours, .theirs])
        for (segment, choice) in MergeToolbar.takeChoices.enumerated() {
            let rig = try MergeRig()
            defer { rig.cleanup() }
            try press(segment: segment, of: rig.controller.toolbar.take)
            #expect(rig.controller.choicesMade == 1, "the press reached the take")
            try await rig.landed()
            #expect(rig.controller.merge?.choices.first == choice)
            #expect(rig.controller.edits.undoActionName == MergeToolbar.takeTitle(choice))
        }
    }

    @Test("Edit ▸ Undo names the take, opens the conflict again and goes back to it")
    func undoAndRedo() async throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let controller = rig.controller
        let window = try #require(controller.window)
        controller.take(.yours)
        try await rig.landed()
        controller.take(.theirs)
        try await rig.landed()
        #expect(controller.merge?.choices == [.yours, .theirs])

        // A pane does not answer `undo:`, so the menu's action reaches the window, whose manager is
        // the controller's.
        #expect(!controller.resultPane.textView.responds(to: Selector(("undo:"))))
        #expect(window.undoManager === controller.edits)
        #expect(controller.edits.undoMenuItemTitle == "Undo Take Theirs")
        controller.goToConflict(0)
        #expect(window.tryToPerform(Selector(("undo:")), with: nil))
        try await rig.landed()
        #expect(controller.merge?.choices == [.yours, nil])
        #expect(controller.currentConflict == 1, "the conflict the undo opened again")
        #expect(controller.resultPane.textView.string == "a\nY\nc\nd\nE\nf\nG\nh\n\nj\n")
        #expect(controller.edits.redoMenuItemTitle == "Redo Take Theirs")

        #expect(window.tryToPerform(Selector(("redo:")), with: nil))
        try await rig.landed()
        #expect(controller.merge?.choices == [.yours, .theirs])

        controller.edits.undo()
        controller.edits.undo()
        try await rig.landed()
        #expect(controller.merge?.choices == [nil, nil])
        #expect(controller.currentConflict == 0)
        #expect(window.isDocumentEdited == false, "back as it opened: nothing to lose")
        #expect(controller.edits.canUndo == false)
    }

    @Test("a take changing one choice to another undoes back to the first")
    func changeAChoice() async throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let controller = rig.controller
        controller.take(.yours)
        try await rig.landed()
        controller.goToConflict(0)
        controller.take(.theirs)
        try await rig.landed()
        #expect(controller.merge?.choices == [.theirs, nil])
        controller.edits.undo()
        try await rig.landed()
        #expect(controller.merge?.choices == [.yours, nil])

        // Taking the choice a conflict already has changes nothing and adds no undo.
        controller.goToConflict(0)
        let made = controller.choicesMade
        controller.take(.yours)
        #expect(controller.choicesMade == made)
        #expect(controller.currentConflict == 1, "it still goes on to the next open conflict")
    }

    @Test("with no current conflict a take does nothing")
    func noCurrentConflict() throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        rig.controller.jump(toRow: 5)
        #expect(rig.controller.handleKey(MergeRig.takeYours))
        #expect(rig.controller.merge?.choices == [nil, nil])
        #expect(rig.controller.edits.canUndo == false)
    }

    @Test("the next open conflict goes round to the start, and is nil when none is left")
    func nextOpenConflict() {
        #expect(MergeWindowController.nextOpenConflict(after: 1, in: [nil, .yours, nil]) == 2)
        #expect(MergeWindowController.nextOpenConflict(after: 2, in: [nil, .yours, .theirs]) == 0)
        #expect(MergeWindowController.nextOpenConflict(after: 0, in: [nil, .yours]) == nil)
        #expect(MergeWindowController.nextOpenConflict(after: 0, in: [nil]) == nil)
    }

    /// `+Layout` answers the delegate's undo-manager question a file away from the conformance, and
    /// AppKit asks only if the runtime can see the answer.
    @Test("the window's delegate hands AppKit the window's undo manager")
    func undoManagerReachesTheRuntime() throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        #expect(rig.controller.responds(
            to: #selector(NSWindowDelegate.windowWillReturnUndoManager(_:))
        ))
        #expect(rig.controller.window?.undoManager === rig.controller.edits)
    }
}

/// Saving the merge window's result, and closing it (PLAN.md §M34 Slice 3): nothing is written while
/// a conflict is open, the save is the compare window's (`ComparedFileSave`, tested in the core),
/// and closing asks about choices a save could keep.
@Suite("Merge window saves")
@MainActor
struct MergeSaveTests {
    /// Counts the window's closes, which `close` makes without asking the delegate again.
    private final class CloseCounter {
        var closed = 0
    }

    /// Choose for both conflicts.
    private func resolve(_ rig: MergeRig) async throws {
        rig.controller.take(.yours)
        try await rig.landed()
        rig.controller.take(.yoursThenTheirs)
        try await rig.landed()
    }

    @Test("⌘S with a conflict open writes nothing and goes to the first open conflict")
    func noSaveWhileOpen() async throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let controller = rig.controller
        controller.take(.theirs)
        try await rig.landed()
        controller.goToConflict(0)
        #expect(!controller.canSave)
        #expect(!controller.toolbar.save.isEnabled)
        #expect(controller.handleKey(MergeRig.commandS))
        #expect(controller.currentConflict == 1)
        #expect(await controller.saveResult() == false)
        #expect(rig.contents == MergeRig.yours)
        #expect(rig.journal.records.isEmpty)
    }

    @Test("once every conflict has a choice, ⌘S writes the result and journals an undoable save")
    func saveWritesTheResult() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-merge-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let rig = try MergeRig(store: ArchiveUndoStore(root: store))
        defer { rig.cleanup() }
        let controller = rig.controller
        try await resolve(rig)
        #expect(controller.canSave)
        #expect(controller.handleKey(MergeRig.commandS))
        try await settleUntil { controller.savedChoices != nil && !controller.isSaving }

        #expect(rig.contents == "a\nY\nc\nd\nE\nf\nG\nh\nI\nK\nj\n")
        #expect(controller.window?.isDocumentEdited == false)
        #expect(!controller.toolbar.save.isEnabled)
        #expect(!controller.canSave)
        let record = try #require(rig.journal.records.first)
        #expect(rig.journal.records.count == 1)
        #expect(record.label == .saveFile)
        // What ⌘Z in a pane of the browser window runs.
        #expect(UndoJournal.revert(record, using: LocalBackend()).succeeded)
        #expect(rig.contents == MergeRig.yours)

        // A choice changed after the save makes the result unsaved again.
        controller.goToConflict(1)
        controller.take(.theirs)
        try await rig.landed()
        #expect(controller.canSave)
        #expect(controller.window?.isDocumentEdited == true)
    }

    @Test("a conflicted working-tree file is replaced whole: its markers never survive a save")
    func markersAreReplaced() async throws {
        let marked = "a\n<<<<<<< ours\nY\n=======\nT\n>>>>>>> theirs\nc\n"
        let rig = try MergeRig(
            base: Data("a\nb\nc\n".utf8),
            yours: Data("a\nY\nc\n".utf8),
            theirs: Data("a\nT\nc\n".utf8),
            target: Data(marked.utf8)
        )
        defer { rig.cleanup() }
        rig.controller.take(.theirs)
        try await rig.landed()
        #expect(await rig.controller.saveResult())
        #expect(rig.contents == "a\nT\nc\n")
    }

    @Test("a file changed since it was read asks first: Cancel keeps it, Save Anyway replaces it")
    func changedSinceRead() async throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        try await resolve(rig)
        try Data("someone else\n".utf8).write(to: URL(fileURLWithPath: rig.path))
        // A different size, so the witness moves whatever the clock's resolution.
        let saving = Task { await rig.controller.saveResult() }
        let sheet = try await rig.sheet()
        #expect(CompareSaveRig.texts(in: sheet.contentView).contains {
            $0.contains("“notes.txt” has changed since this window read it.")
        })
        try await rig.answer(.alertSecondButtonReturn)
        #expect(await saving.value == false)
        #expect(rig.contents == "someone else\n")

        let again = Task { await rig.controller.saveResult() }
        try await rig.answer(.alertFirstButtonReturn)
        #expect(await again.value == true)
        #expect(rig.contents == "a\nY\nc\nd\nE\nf\nG\nh\nI\nK\nj\n")
    }

    @Test("a character yours' encoding cannot hold is refused by name, and nothing is written")
    func unencodableIsReported() async throws {
        let latin = try #require("a\ncafé\nc\n".data(using: .isoLatin1))
        let rig = try MergeRig(
            base: Data("a\nb\nc\n".utf8),
            yours: latin,
            theirs: Data("a\nfrom → to\nc\n".utf8)
        )
        defer { rig.cleanup() }
        rig.controller.take(.theirs)
        try await rig.landed()
        let saving = Task { await rig.controller.saveResult() }
        let sheet = try await rig.sheet()
        #expect(
            CompareSaveRig.texts(in: sheet.contentView).contains { $0.contains("“→” on line 2") }
        )
        try await rig.answer(.alertFirstButtonReturn)
        #expect(await saving.value == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: rig.path)) == latin)
    }

    @Test("a window with no choice made closes without asking")
    func closesWithoutChoices() throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let window = try #require(rig.controller.window)
        #expect(rig.controller.windowShouldClose(window))
        #expect(window.attachedSheet == nil)
    }

    @Test("with a conflict open, closing asks Cancel or Don't Save, and Cancel is the default")
    func closeWhileOpen() async throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let controller = rig.controller
        let window = try #require(controller.window)
        controller.take(.yours)
        try await rig.landed()
        let closes = CloseCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { [closes] _ in closes.closed += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Awaited, so the close it might make has happened before the count is read.
        let cancelled = Task { await controller.closeAfterAsking() }
        let sheet = try await rig.sheet()
        let texts = CompareSaveRig.texts(in: sheet.contentView)
        #expect(texts.contains("Close the merge of “notes.txt” without saving?"))
        #expect(texts.contains {
            $0.hasPrefix("1 conflict is still open, so the result can’t be saved yet.")
        })
        let buttons = CompareSaveRig.buttons(in: sheet.contentView)
        // Cancel in the default slot; `EscapeToDismissTests` pins what Return and ⎋ do there.
        #expect(buttons.map(\.title) == ["Cancel", "Don’t Save"])
        #expect(buttons.last?.keyEquivalent == "d")
        try await rig.answer(.alertFirstButtonReturn)
        await cancelled.value
        #expect(closes.closed == 0, "Cancel kept the window")
        #expect(controller.merge?.choices == [.yours, nil])

        #expect(controller.handleKey(MergeRig.commandW))
        _ = try await rig.sheet()
        #expect(!controller.windowShouldClose(window), "a second ⌘W asks nothing more")
        try await rig.answer(.alertSecondButtonReturn)
        try await settleUntil { closes.closed == 1 }
        #expect(rig.contents == MergeRig.yours, "Don't Save wrote nothing")
    }

    @Test("with every conflict chosen, closing asks Save first, and Save writes before closing")
    func closeWhenResolved() async throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        try await resolve(rig)
        let closing = Task { await rig.controller.closeAfterAsking() }
        let sheet = try await rig.sheet()
        #expect(CompareSaveRig.texts(in: sheet.contentView).contains(
            "Do you want to save the merge of “notes.txt”?"
        ))
        try await rig.answer(.alertFirstButtonReturn)
        await closing.value
        #expect(rig.contents == "a\nY\nc\nd\nE\nf\nG\nh\nI\nK\nj\n")
        #expect(!rig.controller.hasUnsavedChoices)
    }
}
