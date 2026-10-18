import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A Force Click on a row renames it, as one on a name does in Finder.
///
/// `NSEvent` has no factory for a pressure event, so nothing here can send the real one. What a test
/// can drive is everything around it: the recognizer's stages as plain numbers, and the press itself
/// through the table's own `mouseDown`, with the stage then handed to `forceClickStageChanged(to:)`,
/// the one line `pressureChange(with:)` adds. The order is the measured one (docs/NOTES.md ▸ Mouse,
/// trackpad and animation): the pressure events of a press arrive after `mouseDown` has returned.
@MainActor
@Suite("Force Click renames", .serialized)
struct ForceClickRenameTests {
    // MARK: - The recognizer

    @Test("a plain press answers once, when it reaches stage 2")
    func answersOnceAtStageTwo() {
        var recognizer = ForceClickRecognizer()
        recognizer.arm(row: 3)

        #expect(recognizer.pressureChanged(toStage: 1) == nil)
        #expect(recognizer.pressureChanged(toStage: 2) == 3)
        // A press holds stage 2 for many events, and eases back through stage 1 before the release.
        #expect(recognizer.pressureChanged(toStage: 2) == nil)
        #expect(recognizer.pressureChanged(toStage: 1) == nil)
        #expect(recognizer.pressureChanged(toStage: 0) == nil)
    }

    @Test("a press that armed nothing answers nothing")
    func anUnarmedPressAnswersNothing() {
        var recognizer = ForceClickRecognizer()

        #expect(recognizer.pressureChanged(toStage: 1) == nil)
        #expect(recognizer.pressureChanged(toStage: 2) == nil)
    }

    @Test("a press that became a drag answers nothing")
    func aDragDisarms() {
        var recognizer = ForceClickRecognizer()
        recognizer.arm(row: 2)
        recognizer.disarm()

        #expect(recognizer.pressureChanged(toStage: 2) == nil)
    }

    @Test("the release disarms, so a later stage 2 does not reach back to the row")
    func theReleaseDisarms() {
        var recognizer = ForceClickRecognizer()
        recognizer.arm(row: 4)
        _ = recognizer.pressureChanged(toStage: 1)
        _ = recognizer.pressureChanged(toStage: 0)

        #expect(recognizer.pressureChanged(toStage: 2) == nil)
    }

    // MARK: - The press, through the table

    private static let here = VFSPath.local("/tmp/dirnex-force-click")
    private static let folder = Handoff.local("/tmp/dirnex-force-click/Docs", kind: .directory)
    private static let notes = Handoff.local("/tmp/dirnex-force-click/notes.txt")
    private static let todo = Handoff.local("/tmp/dirnex-force-click/todo.txt")

    /// A pane laid out in a window, listing a folder it can rename in, with a `..` row on top.
    private func makePane() async throws -> WindowedPane {
        let entries = [Self.folder, Self.notes, Self.todo]
        let backend = Handoff.StubBackend(
            capabilities: [.read, .write, .rename],
            listings: [Self.here: entries]
        )
        let fixture = windowedPane(showing: entries, at: Self.here, backend: backend)
        // Waited for, so that the listing cannot land over the rows a press is aimed at.
        try await settleUntil { fixture.pane.tabs[0].hasLoaded }
        fixture.window.layoutIfNeeded()
        fixture.pane.tableView.layoutSubtreeIfNeeded()
        return fixture
    }

    private func row(of entry: FileEntry, in fixture: WindowedPane) throws -> Int {
        let index = try #require(fixture.pane.panel.displayedIndex(ofID: entry.path))
        return fixture.pane.row(forEntryIndex: index)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        row: Int,
        _ modifiers: NSEvent.ModifierFlags,
        in fixture: WindowedPane
    ) throws -> NSEvent {
        let table = fixture.pane.tableView
        let rect = table.rect(ofRow: row)
        return try #require(NSEvent.mouseEvent(
            with: type,
            location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    /// A press on `row`. A plain one runs `NSTableView`'s own tracking loop, which waits for the
    /// release, so the release is queued ahead of it and `mouseDown` returns as it does when the button
    /// comes up. A ⌘-click is consumed before that loop and gets none, which would otherwise be left
    /// in the queue for some later press to end on.
    ///
    /// **The cursor is put on the row first, because the table's own click does not do it here.**
    /// Measured 2026-10-18: in the test host, which is never the active app, the loop takes the queued
    /// release and returns with the selection unmoved, whether the window is on screen or not, and
    /// `NSWindow.sendEvent` delivers nothing at all (the press goes to activating the window). In the
    /// app the click selects the row before any pressure event arrives, which the live run showed.
    private func press(row: Int, _ modifiers: NSEvent.ModifierFlags = [], in fixture: WindowedPane) throws {
        let table = fixture.pane.tableView
        let down = try mouseEvent(.leftMouseDown, row: row, modifiers, in: fixture)
        // The press must land on the row it is aimed at, or the rest proves nothing.
        #expect(table.row(at: table.convert(down.locationInWindow, from: nil)) == row)
        if modifiers.isEmpty {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            NSApp.postEvent(try mouseEvent(.leftMouseUp, row: row, [], in: fixture), atStart: true)
        }
        table.mouseDown(with: down)
        if modifiers.isEmpty {
            #expect(NSApp.currentEvent?.type == .leftMouseUp)
        }
    }

    /// The pressure events a Force Click delivers once the button is up, in the measured order.
    private func forceClickStages(on table: FileTableView) {
        for stage in [1, 1, 2, 2, 1, 0] {
            table.forceClickStageChanged(to: stage)
        }
    }

    @Test("a Force Click on a file opens its name for editing")
    func aForceClickRenamesTheRow() async throws {
        let fixture = try await makePane()
        let row = try row(of: Self.notes, in: fixture)

        try press(row: row, in: fixture)
        // The click alone opens nothing.
        #expect(fixture.pane.renamingEntryID == nil)

        forceClickStages(on: fixture.pane.tableView)

        #expect(fixture.pane.renamingEntryID == Self.notes.path)
        #expect((fixture.window.firstResponder as? NSText)?.string == "notes.txt")
    }

    @Test("a plain press that never reaches stage 2 renames nothing")
    func anOrdinaryClickRenamesNothing() async throws {
        let fixture = try await makePane()

        try press(row: try row(of: Self.notes, in: fixture), in: fixture)
        for stage in [1, 1, 0] {
            fixture.pane.tableView.forceClickStageChanged(to: stage)
        }

        #expect(fixture.pane.renamingEntryID == nil)
    }

    @Test("a Force Click on `..` renames nothing, as F2 there does nothing")
    func theParentRowIsNotRenamed() async throws {
        let fixture = try await makePane()
        #expect(fixture.pane.isParentRow(0))

        try press(row: 0, in: fixture)
        forceClickStages(on: fixture.pane.tableView)

        #expect(fixture.pane.renamingEntryID == nil)
    }

    /// The press that begins a ⌘-click is consumed before the table's own click and must arm nothing,
    /// even right after a plain click on the same row that armed it and delivered no pressure at all,
    /// as a click with a mouse does.
    @Test("a ⌘-Force Click marks the row and renames nothing")
    func aCommandForceClickOnlyMarks() async throws {
        let fixture = try await makePane()
        let row = try row(of: Self.todo, in: fixture)

        try press(row: row, in: fixture)
        try press(row: row, .command, in: fixture)
        forceClickStages(on: fixture.pane.tableView)

        #expect(fixture.pane.panel.selection == [Self.todo.path])
        #expect(fixture.pane.tableView.selectedRow == row)
        #expect(fixture.pane.renamingEntryID == nil)
    }

    @Test("a Force Click answered for a row the cursor is not on renames nothing")
    func onlyTheCursorRow() async throws {
        let fixture = try await makePane()
        let notesRow = try row(of: Self.notes, in: fixture)
        try press(row: notesRow, in: fixture)

        fixture.pane.fileTable(
            fixture.pane.tableView,
            didForceClickRow: try row(of: Self.todo, in: fixture)
        )

        #expect(fixture.pane.renamingEntryID == nil)
    }
}
