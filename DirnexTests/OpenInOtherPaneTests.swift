import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// ⌘Return and ⌘-double-click: open the folder or archive under the cursor in a new tab of the other
/// pane, leaving this pane where it is.
///
/// Each test drives the real key or mouse event into a pane laid out in a window, with a second
/// loaded pane as its counterpart, and reads both panes' tabs. Nothing lists a real directory: both
/// panes stand on a stub backend that lists what it is told to.
///
/// What is not here is anything that ends in a connect, an unlock or an extraction: a bucket, a
/// vault, a nested archive and an archive on a server each land through `navigate(to:inOtherPane:)`
/// after work this target cannot do without a server, the Keychain or `bsdtar`.
@MainActor
@Suite("Open in a new tab of the other pane", .serialized)
struct OpenInOtherPaneTests {
    private static let here = VFSPath.local("/tmp/dirnex-other-pane")
    private static let folder = Handoff.local("/tmp/dirnex-other-pane/Docs", kind: .directory)
    private static let archive = Handoff.local("/tmp/dirnex-other-pane/backup.zip")
    private static let notes = Handoff.local("/tmp/dirnex-other-pane/notes.txt")

    /// The pane under test, in a window with its rows drawn, and the pane beside it.
    @MainActor
    private struct Panes {
        let source: WindowedPane
        let other: PanelViewController

        var pane: PanelViewController { source.pane }
        var table: FileTableView { source.pane.tableView }

        /// The table row `entry` is drawn on.
        func row(of entry: FileEntry) throws -> Int {
            let index = try #require(pane.panel.displayedIndex(ofID: entry.path))
            return pane.row(forEntryIndex: index)
        }

        func putCursor(on entry: FileEntry) throws {
            let index = try #require(pane.panel.displayedIndex(ofID: entry.path))
            pane.panel.moveCursor(to: index)
            pane.cursorOnParentRow = false
        }

        /// The paths of the other pane's tabs, in order.
        var otherTabs: [VFSPath] { other.tabs.map { $0.panel.path } }
    }

    private func makePanes() async throws -> Panes {
        let entries = [Self.folder, Self.archive, Self.notes]
        let backend = Handoff.StubBackend(listings: [Self.here: entries])
        let source = windowedPane(showing: entries, at: Self.here, backend: backend)
        let other = windowedPane(at: .local("/tmp"), backend: backend)
        source.host.counterpart = other.pane
        // Both panes list their folder on load. Waited for, so that a later listing cannot land over
        // what a test arranged, and so the rows a click is aimed at are the rows drawn.
        try await settleUntil { source.pane.tabs[0].hasLoaded && other.pane.tabs[0].hasLoaded }
        source.window.layoutIfNeeded()
        source.pane.tableView.layoutSubtreeIfNeeded()
        return Panes(source: source, other: other.pane)
    }

    // MARK: - The keyboard

    private func returnKey(
        _ modifiers: NSEvent.ModifierFlags,
        keypad: Bool = false
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: keypad ? "\u{3}" : "\r",
            charactersIgnoringModifiers: keypad ? "\u{3}" : "\r",
            isARepeat: false,
            keyCode: keypad ? 76 : 36
        ))
    }

    @Test("⌘Return opens the folder in a new tab of the other pane, and this pane stays put")
    func commandReturnOpensAFolderOverThere() async throws {
        let panes = try await makePanes()
        try panes.putCursor(on: Self.folder)

        panes.table.keyDown(with: try returnKey(.command))

        #expect(panes.otherTabs == [.local("/tmp"), Self.folder.path])
        // The new tab is the one the other pane now shows: it is where F5 copies to next.
        #expect(panes.other.activeTabIndex == 1)
        #expect(panes.pane.tabs.count == 1)
        #expect(panes.pane.panel.path == Self.here)
    }

    @Test("a local archive opens at its root over there")
    func commandReturnOpensAnArchiveOverThere() async throws {
        let panes = try await makePanes()
        try panes.putCursor(on: Self.archive)

        panes.table.keyDown(with: try returnKey(.command))

        let root = VFSPath(backend: .archive(forArchiveAt: Self.archive.path.path), path: "/")
        #expect(panes.otherTabs == [.local("/tmp"), root])
        #expect(panes.pane.panel.path == Self.here)
    }

    /// Keypad Enter carries the numeric-pad flag, fn+Return the function flag, and Caps Lock its own.
    /// A check written as `flags == .command` misses all three.
    @Test("⌘Enter, fn⌘Return and ⌘Return with Caps Lock on are the same key; ⌥⌘ and ⇧⌘ are not")
    func theSpellingsOfTheKey() async throws {
        let panes = try await makePanes()
        try panes.putCursor(on: Self.folder)

        panes.table.keyDown(with: try returnKey([.command, .numericPad], keypad: true))
        panes.table.keyDown(with: try returnKey([.command, .function], keypad: true))
        panes.table.keyDown(with: try returnKey([.command, .capsLock]))
        #expect(panes.other.tabs.count == 4)

        panes.table.keyDown(with: try returnKey([.command, .option]))
        panes.table.keyDown(with: try returnKey([.command, .shift]))
        #expect(panes.other.tabs.count == 4)
        #expect(panes.pane.panel.path == Self.here)
    }

    @Test("Return without ⌘ still opens the folder here, and nothing over there")
    func plainReturnIsUnchanged() async throws {
        let panes = try await makePanes()
        try panes.putCursor(on: Self.folder)

        panes.table.keyDown(with: try returnKey([]))

        try await settleUntil { panes.pane.panel.path == Self.folder.path }
        #expect(panes.otherTabs == [.local("/tmp")])
    }

    @Test("⌘Return on `..` goes up here, as Return does, and opens nothing over there")
    func commandReturnOnTheParentRow() async throws {
        let panes = try await makePanes()
        panes.pane.cursorOnParentRow = true

        panes.table.keyDown(with: try returnKey(.command))

        try await settleUntil { panes.pane.panel.path == .local("/tmp") }
        #expect(panes.otherTabs == [.local("/tmp")])
    }

    /// A file has no tab to open in, so ⌘ changes nothing: it takes the route Return takes. Read on a
    /// file on a server, whose route is a fetch the stub host records, because a local one would be
    /// handed to a real application.
    @Test("⌘Return on a file opens it as Return does, with no tab anywhere")
    func commandReturnOnAFile() {
        let pdf = Handoff.remote("/srv/report.pdf")
        let source = windowedPane(
            showing: [pdf],
            at: VFSPath(backend: Handoff.remoteID, path: "/srv")
        )
        let other = windowedPane(at: .local("/tmp"))
        source.host.counterpart = other.pane
        source.pane.panel.moveCursor(to: 0)

        source.pane.openCurrentEntry(inOtherPane: true)

        #expect(other.pane.tabs.count == 1)
        #expect(source.pane.tabs.count == 1)
    }

    // MARK: - The mouse

    /// A ⌘-mouse-down at the middle of `row`, as the `clicks`-th click of a run.
    private func click(row: Int, clicks: Int, in panes: Panes) throws -> NSEvent {
        let rect = panes.table.rect(ofRow: row)
        let point = panes.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panes.source.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        ))
    }

    @Test("⌘-double-click opens the folder over there and leaves the marks as they were")
    func commandDoubleClickOpensAFolderOverThere() async throws {
        let panes = try await makePanes()
        // A mark made before the gesture, which it must leave alone.
        panes.pane.panel.setSelection([Self.notes.path])
        let row = try panes.row(of: Self.folder)
        let first = try click(row: row, clicks: 1, in: panes)
        // The click must land on the row it is aimed at, or the rest proves nothing.
        #expect(panes.table.row(at: panes.table.convert(first.locationInWindow, from: nil)) == row)

        panes.table.mouseDown(with: first)
        // The first click is an ordinary ⌘-click, and marks the row.
        #expect(panes.pane.panel.selection == [Self.notes.path, Self.folder.path])
        #expect(panes.source.host.selectionJournal.records.count == 1)

        panes.table.mouseDown(with: try click(row: row, clicks: 2, in: panes))

        #expect(panes.otherTabs == [.local("/tmp"), Self.folder.path])
        #expect(panes.pane.panel.path == Self.here)
        // The second takes that mark back, and the journal entry with it, so ⌘Z does not stop on a
        // mark nobody meant to make.
        #expect(panes.pane.panel.selection == [Self.notes.path])
        #expect(panes.source.host.selectionJournal.records.isEmpty)
    }

    @Test("a third click opens nothing more and marks nothing")
    func aThirdClickIsSwallowed() async throws {
        let panes = try await makePanes()
        let row = try panes.row(of: Self.folder)

        panes.table.mouseDown(with: try click(row: row, clicks: 1, in: panes))
        panes.table.mouseDown(with: try click(row: row, clicks: 2, in: panes))
        panes.table.mouseDown(with: try click(row: row, clicks: 3, in: panes))

        #expect(panes.otherTabs == [.local("/tmp"), Self.folder.path])
        #expect(panes.pane.panel.selection.isEmpty)
    }

    /// A ⌘-click made on its own is a mark the user meant. A plain click in between ends the pair,
    /// so a ⌘-click that the system then counts as the second of a double still opens the row, but
    /// does not take back a mark it did not make.
    @Test("a ⌘-double-click that did not start with a ⌘-click takes back no mark")
    func aMarkMadeEarlierStays() async throws {
        let panes = try await makePanes()
        let row = try panes.row(of: Self.folder)
        panes.table.mouseDown(with: try click(row: row, clicks: 1, in: panes))
        #expect(panes.pane.panel.selection == [Self.folder.path])

        // The plain click, through the seam `mouseDown` hands it to before `super`. `super` itself
        // runs the table's tracking loop, which waits for a mouse-up no test posts.
        _ = panes.pane.fileTable(panes.table, didClickRow: row, modifiers: [])
        panes.table.mouseDown(with: try click(row: row, clicks: 2, in: panes))

        #expect(panes.otherTabs == [.local("/tmp"), Self.folder.path])
        #expect(panes.pane.panel.selection == [Self.folder.path])
        #expect(panes.source.host.selectionJournal.records.count == 1)
    }

    @Test("a ⌘-click alone still only marks")
    func aCommandClickAloneMarks() async throws {
        let panes = try await makePanes()
        panes.table.mouseDown(
            with: try click(row: try panes.row(of: Self.folder), clicks: 1, in: panes)
        )

        #expect(panes.pane.panel.selection == [Self.folder.path])
        #expect(panes.otherTabs == [.local("/tmp")])
    }
}
