import AppKit
import Foundation
import Testing

@testable import Dirnex

/// Holding ⌘ floats the cursor row's full name (`CursorNamePeek`).
///
/// The ⌘ hold itself is a local event monitor and a timer, which a headless test cannot press. What
/// it can reach is everything after the hold: which row and label the panel is for, whether it goes
/// up at all, and where it lands. What the panel draws is `ExpansionPanelTests`'. The hold was checked
/// in the running app.
@Suite("Cursor name peek")
@MainActor
struct CursorNamePeekTests {
    static let longName = ExpansionTableFixture.longName

    @Test("only ⌘ alone counts as the hold; the locks and fn do not get in its way")
    func commandAloneIsTheHold() {
        #expect(CursorNamePeek.holdsCommandAlone(.command))
        #expect(CursorNamePeek.holdsCommandAlone([.command, .capsLock, .function]))
        #expect(!CursorNamePeek.holdsCommandAlone([.command, .shift]))
        #expect(!CursorNamePeek.holdsCommandAlone([.command, .option]))
        #expect(!CursorNamePeek.holdsCommandAlone(.option))
        #expect(!CursorNamePeek.holdsCommandAlone([]))
    }

    /// The panel goes up for a truncated cursor row, padded out around the label like the hover
    /// panel, as a child of the pane's window — and comes down with nothing left behind.
    @Test("a truncated cursor row floats its name, and hiding takes the panel away")
    func truncatedCursorRowFloats() throws {
        let fixture = ExpansionTableFixture(names: [Self.longName, "a.txt"])
        defer { ExpansionPanel.hide() }
        fixture.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let label = try #require(CursorNamePeek.cursorNameLabel(in: fixture.table))
        #expect(label.stringValue == Self.longName)
        #expect(CursorNamePeek.show(for: fixture.table))
        let panel = try #require(ExpansionPanel.shownPanel)
        #expect(ExpansionPanel.owner == .commandHold)
        #expect(fixture.window.childWindows?.contains(panel) == true)

        let labelOnScreen = fixture.window.convertToScreen(label.convert(label.bounds, to: nil))
        let padding = ExpandingLabelCell.padding
        #expect(abs(panel.frame.minX - (labelOnScreen.minX - padding.width)) < 1)
        #expect(panel.frame.width > labelOnScreen.width + 2 * padding.width)
        #expect(panel.ignoresMouseEvents)

        CursorNamePeek.hide()
        #expect(ExpansionPanel.shownPanel == nil)
        #expect(ExpansionPanel.owner == nil)
        #expect(fixture.window.childWindows?.isEmpty ?? true)
    }

    /// The case that makes the one above mean something: the same table, the same call, and a name
    /// that fits puts nothing up.
    @Test("a cursor row whose name fits floats nothing")
    func fittingCursorRowFloatsNothing() throws {
        let fixture = ExpansionTableFixture(names: [Self.longName, "a.txt"])
        defer { ExpansionPanel.hide() }
        fixture.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        #expect(
            try #require(CursorNamePeek.cursorNameLabel(in: fixture.table)).stringValue == "a.txt"
        )
        #expect(!CursorNamePeek.show(for: fixture.table))
        #expect(ExpansionPanel.shownPanel == nil)
    }

    @Test("a cursor scrolled out of view floats nothing")
    func offscreenCursorFloatsNothing() {
        let fixture = ExpansionTableFixture(names: Array(repeating: Self.longName, count: 200))
        defer { ExpansionPanel.hide() }
        fixture.table.selectRowIndexes(IndexSet(integer: 199), byExtendingSelection: false)

        #expect(CursorNamePeek.cursorNameLabel(in: fixture.table) == nil)
        #expect(!CursorNamePeek.show(for: fixture.table))
    }
}
