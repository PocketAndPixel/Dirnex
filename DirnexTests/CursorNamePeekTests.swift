import AppKit
import Foundation
import Testing

@testable import Dirnex

/// Holding ⌘ floats the cursor row's full name (`CursorNamePeek`).
///
/// The ⌘ hold itself is a local event monitor and a timer, which a headless test cannot press. What
/// it can reach is everything after the hold: which row and label the panel is for, whether it goes
/// up at all, where it lands, and what it draws. The hold was checked in the running app.
@Suite("Cursor name peek")
@MainActor
struct CursorNamePeekTests {
    static let longName = "WestWorld.S01E09.The.Well-Tempered.Clavier.mkv"

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
        let fixture = Fixture(names: [Self.longName, "a.txt"])
        defer { CursorNamePeek.hide() }
        fixture.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let label = try #require(CursorNamePeek.cursorNameLabel(in: fixture.table))
        #expect(label.stringValue == Self.longName)
        #expect(CursorNamePeek.show(for: fixture.table))
        let panel = try #require(CursorNamePeek.shownPanel)
        #expect(fixture.window.childWindows?.contains(panel) == true)

        let labelOnScreen = fixture.window.convertToScreen(label.convert(label.bounds, to: nil))
        let padding = ExpandingLabelCell.padding
        #expect(abs(panel.frame.minX - (labelOnScreen.minX - padding.width)) < 1)
        #expect(panel.frame.width > labelOnScreen.width + 2 * padding.width)
        #expect(panel.ignoresMouseEvents)

        CursorNamePeek.hide()
        #expect(CursorNamePeek.shownPanel == nil)
        #expect(fixture.window.childWindows?.isEmpty ?? true)
    }

    /// The case that makes the one above mean something: the same table, the same call, and a name
    /// that fits puts nothing up.
    @Test("a cursor row whose name fits floats nothing")
    func fittingCursorRowFloatsNothing() throws {
        let fixture = Fixture(names: [Self.longName, "a.txt"])
        defer { CursorNamePeek.hide() }
        fixture.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        #expect(
            try #require(CursorNamePeek.cursorNameLabel(in: fixture.table)).stringValue == "a.txt"
        )
        #expect(!CursorNamePeek.show(for: fixture.table))
        #expect(CursorNamePeek.shownPanel == nil)
    }

    @Test("a cursor scrolled out of view floats nothing")
    func offscreenCursorFloatsNothing() {
        let fixture = Fixture(names: Array(repeating: Self.longName, count: 200))
        defer { CursorNamePeek.hide() }
        fixture.table.selectRowIndexes(IndexSet(integer: 199), byExtendingSelection: false)

        #expect(CursorNamePeek.cursorNameLabel(in: fixture.table) == nil)
        #expect(!CursorNamePeek.show(for: fixture.table))
    }

    /// The panel draws a copy, not the row's own cell, and the copy has to carry what the panel
    /// draws: the name, the font (bold for a marked row) and the resting ink rather than the cursor's.
    @Test("the floated copy carries the name, the font and the resting ink")
    func snapshotCarriesWhatThePanelDraws() throws {
        let cell = FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
        cell.textField?.stringValue = Self.longName
        cell.marked = true
        cell.backgroundStyle = .emphasized
        cell.applyStyle()
        let label = try #require(cell.textField)

        let copy = CursorNamePeek.snapshot(of: label)
        #expect(copy.stringValue == Self.longName)
        #expect(copy.font == label.font)
        #expect(copy.expansionInk == cell.palette.resolvedMark)
        #expect(copy !== label.cell)
    }

    /// A pane's table in a window of its own, with a Name column too narrow for `longName`.
    @MainActor
    private final class Fixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let table = FileTableView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        private let names: [String]

        /// Kept for the life of the test host: tearing a test window down can crash a later test
        /// (docs/NOTES.md ▸ Testing, windows in a test).
        private static var retained: [Fixture] = []

        init(names: [String]) {
            self.names = names
            super.init()
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(PanelViewController.Column.name.rawValue)
            )
            column.width = 200
            table.addTableColumn(column)
            table.style = .plain
            table.dataSource = self
            table.delegate = self
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 200))
            scrollView.documentView = table
            window.contentView = NSView(frame: scrollView.frame)
            window.contentView?.addSubview(scrollView)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            table.reloadData()
            for _ in 0..<2 {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            Self.retained.append(self)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { names.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = FileCellView(
                showsImage: true,
                identifier: NSUserInterfaceItemIdentifier("name")
            )
            cell.textField?.stringValue = names[row]
            return cell
        }
    }
}
