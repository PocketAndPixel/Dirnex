import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Closing a compare window with edits a save could keep (PLAN.md §M33 Slice 3): Save, Don't Save
/// or Cancel, as any Mac app asks.
@Suite("Compare window close prompt")
@MainActor
struct CompareCloseTests {
    /// Counts the window's closes, which `close` makes without asking the delegate again.
    private final class CloseCounter {
        var closed = 0
        var observer: (any NSObjectProtocol)?
    }

    private func watchCloses(_ rig: CompareSaveRig) -> CloseCounter {
        let counter = CloseCounter()
        counter.observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: rig.controller.window,
            queue: nil
        ) { [counter] _ in counter.closed += 1 }
        return counter
    }

    @Test("a window with nothing unsaved closes without asking")
    func uneditedCloses() throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        let window = try #require(rig.controller.window)
        #expect(rig.controller.windowShouldClose(window))
        #expect(window.attachedSheet == nil)
    }

    @Test("an edited window asks, and Cancel keeps it open with its edits")
    func cancelKeepsTheWindow() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        let closes = watchCloses(rig)
        try await rig.copy(to: .right)
        let window = try #require(rig.controller.window)

        #expect(!rig.controller.windowShouldClose(window))
        let sheet = try await rig.sheet()
        #expect(CompareSaveRig.texts(in: sheet.contentView).contains { $0.contains("“right.txt”") })
        // A second ⌘W while the question is up asks nothing more.
        #expect(!rig.controller.windowShouldClose(window))
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await settleUntil { window.attachedSheet == nil }

        #expect(closes.closed == 0)
        #expect(rig.controller.unsavedSides == [.right])
        #expect(rig.contents(rig.rightPath) == "a\nb\nc\n")
    }

    @Test("⌘W closes as the close button does: after asking with an edit, at once without one")
    func commandWCloses() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        let closes = watchCloses(rig)
        try await rig.copy(to: .right)

        #expect(rig.controller.handleKey(CompareSaveRig.commandW))
        try await rig.answer(.alertSecondButtonReturn)
        try await settleUntil { rig.controller.window?.attachedSheet == nil }
        #expect(closes.closed == 0)

        rig.controller.edits.undo()
        try await settleUntil { rig.controller.comparedRevision == rig.controller.sidesRevision }
        #expect(rig.controller.unsavedSides.isEmpty)
        #expect(rig.controller.handleKey(CompareSaveRig.commandW))
        try await settleUntil { closes.closed == 1 }
        #expect(rig.contents(rig.rightPath) == "a\nb\nc\n")
    }

    @Test("Don't Save closes the window and writes nothing")
    func dontSaveCloses() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        let closes = watchCloses(rig)
        try await rig.copy(to: .right)

        #expect(try !rig.controller.windowShouldClose(#require(rig.controller.window)))
        try await rig.answer(.alertThirdButtonReturn)
        try await settleUntil { closes.closed == 1 }
        #expect(rig.contents(rig.rightPath) == "a\nb\nc\n")
    }

    @Test("Save writes the edited file, then closes the window")
    func saveThenClose() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        let closes = watchCloses(rig)
        try await rig.copy(to: .right)

        #expect(try !rig.controller.windowShouldClose(#require(rig.controller.window)))
        try await rig.answer(.alertFirstButtonReturn)
        try await settleUntil { closes.closed == 1 }
        #expect(rig.contents(rig.rightPath) == "a\nB\nc\n")
    }

    @Test("a save that does not happen keeps the window open")
    func refusedSaveKeepsTheWindow() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        let closes = watchCloses(rig)
        try await rig.copy(to: .right)
        try Data("somebody else's\n".utf8).write(to: URL(fileURLWithPath: rig.rightPath))

        #expect(try !rig.controller.windowShouldClose(#require(rig.controller.window)))
        try await rig.answer(.alertFirstButtonReturn)
        // Save, then the file turns out changed: Cancel there leaves the window as it was.
        try await settleUntil {
            (rig.controller.window?.attachedSheet).map {
                CompareSaveRig.texts(in: $0.contentView).contains { $0.contains("has changed") }
            } ?? false
        }
        try await rig.answer(.alertSecondButtonReturn)
        try await settleUntil { rig.controller.isSaving == false && rig.controller.window?.attachedSheet == nil }
        #expect(closes.closed == 0)
        #expect(rig.contents(rig.rightPath) == "somebody else's\n")
    }

    @Test("with both sides edited, the question names both files and Don't Save is ⌘D")
    func bothSidesNamed() async throws {
        let rig = try CompareSaveRig("a\nB\nc\nD\ne\n", "a\nb\nc\nd\ne\n")
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        try await rig.copy(to: .left)
        #expect(rig.controller.unsavedSides == [.left, .right])

        let asking = Task { await rig.controller.askAboutUnsavedSides() }
        let sheet = try await rig.sheet()
        let texts = CompareSaveRig.texts(in: sheet.contentView)
        #expect(texts.contains { $0.contains("“left.txt”") && $0.contains("“right.txt”") })
        let buttons = CompareSaveRig.buttons(in: sheet.contentView)
        #expect(
            buttons.contains { $0.keyEquivalent == "d" && $0.keyEquivalentModifierMask == .command }
        )
        rig.controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        #expect(await asking.value == .cancel)
    }
}
