import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The context menu from the keyboard (2026-10-25): a lone tap of ⌥ (`OptionTapMenu`), and the
/// File menu's Show Context Menu, which the palette and a user's own chord also reach.
///
/// A headless test cannot press ⌥, and the menu's own event loop would wedge the run, so neither
/// the key nor the pop-up is driven. What is pinned is everything between them: the tap decided
/// from real `NSEvent`s, which table answers it, the menu the keyboard gets and what it acts on,
/// and the wiring the File menu dispatches through. The tap was checked in the running app.
@MainActor
@Suite("Keyboard context menu")
struct KeyboardContextMenuTests {
    private let rows = ["a.txt", "b.txt", "c.txt"].map { Handoff.local("/tmp/probe/\($0)") }

    // MARK: - The tap, from events

    private func flags(_ flags: NSEvent.ModifierFlags, at time: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: time,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 58
        ))
    }

    private func letter(_ text: String, flags: NSEvent.ModifierFlags, at time: TimeInterval) throws
        -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: 14
        ))
    }

    @Test("⌥ pressed and let go is a tap, and Caps Lock or fn on with it changes nothing")
    func pressAndRelease() throws {
        var tap = OptionTapMenu.recognizer()
        #expect(try !OptionTapMenu.ends(flags(.option, at: 1.0), tap: &tap))
        #expect(try OptionTapMenu.ends(flags([], at: 1.1), tap: &tap))

        #expect(try !OptionTapMenu.ends(flags([.option, .capsLock, .function], at: 2.0), tap: &tap))
        #expect(try OptionTapMenu.ends(flags([.capsLock, .function], at: 2.1), tap: &tap))
    }

    /// ⌥E is how é is typed into type-to-filter. The key between press and release is what keeps
    /// the release from opening a menu over the filter.
    @Test("a key typed with ⌥ held spoils the tap")
    func keyBetween() throws {
        var tap = OptionTapMenu.recognizer()
        _ = try OptionTapMenu.ends(flags(.option, at: 1.0), tap: &tap)
        #expect(try !OptionTapMenu.ends(letter("´", flags: .option, at: 1.05), tap: &tap))
        #expect(try !OptionTapMenu.ends(flags([], at: 1.1), tap: &tap))
    }

    @Test("a press held past the tab-number delay is a hold, not a tap")
    func heldTooLong() throws {
        var tap = OptionTapMenu.recognizer()
        _ = try OptionTapMenu.ends(flags(.option, at: 1.0), tap: &tap)
        #expect(
            try !OptionTapMenu.ends(flags([], at: 1.0 + TabShortcuts.revealDelay + 0.05), tap: &tap)
        )
    }

    // MARK: - Who answers

    @Test("only a file list holding the focus answers the tap")
    func focusedTableOnly() throws {
        let hosted = windowedPane(showing: rows, at: .local("/tmp/probe"))
        let pane = hosted.pane
        pane.focusTable()
        #expect(OptionTapMenu.focusedTable(in: hosted.window) === pane.tableView)

        // A text field taking the focus (a rename, the path field) puts a field editor in front.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        pane.view.addSubview(field)
        defer { field.removeFromSuperview() }
        #expect(hosted.window.makeFirstResponder(field))
        #expect(OptionTapMenu.focusedTable(in: hosted.window) == nil)
        #expect(OptionTapMenu.focusedTable(in: nil) == nil)
    }

    // MARK: - The menu

    private func isEntryMenu(_ menu: NSMenu) -> Bool {
        menu.items.contains { $0.action == NSSelectorFromString("openContextEntry:") }
    }

    private func folderShown(by menu: NSMenu) -> VFSPath? {
        menu.items.first { $0.action == NSSelectorFromString("showFolderAttributes:") }?
            .representedObject as? VFSPath
    }

    /// The control is the right-click on the same row, which collapses the marks onto it because
    /// the pointer chose it. The keyboard chose nothing, so the marks stay and the menu is theirs.
    @Test("with marks the menu is theirs, and the marks are left alone")
    func marksStay() {
        let hosted = windowedPane(showing: rows, at: .local("/tmp/probe"))
        let pane = hosted.pane
        pane.panel.setSelection([rows[0].path, rows[2].path])
        pane.panel.moveCursor(to: 1)

        #expect(isEntryMenu(pane.keyboardContextMenu()))
        #expect(Set(pane.selectionTargets().map(\.name)) == ["a.txt", "c.txt"])

        _ = pane.contextMenu(forRow: pane.row(forEntryIndex: 1))
        #expect(pane.selectionTargets().map(\.name) == ["b.txt"])
    }

    @Test("with no marks the menu is the cursor row's")
    func cursorRow() {
        let hosted = windowedPane(showing: rows, at: .local("/tmp/probe"))
        let pane = hosted.pane
        pane.panel.moveCursor(to: 2)

        #expect(isEntryMenu(pane.keyboardContextMenu()))
        #expect(pane.selectionTargets().map(\.name) == ["c.txt"])
    }

    @Test("on `..` the menu is the folder it leads to, as a right-click there gives")
    func parentRow() {
        let hosted = windowedPane(showing: rows, at: .local("/tmp/probe"))
        let pane = hosted.pane
        pane.cursorOnParentRow = true

        let menu = pane.keyboardContextMenu()
        #expect(!isEntryMenu(menu))
        #expect(folderShown(by: menu) == .local("/tmp"))
    }

    /// The marks outrank the cursor for every command in the pane, so they do here too.
    @Test("on `..` with marks the menu is the marks'")
    func parentRowWithMarks() {
        let hosted = windowedPane(showing: rows, at: .local("/tmp/probe"))
        let pane = hosted.pane
        pane.panel.setSelection([rows[1].path])
        pane.cursorOnParentRow = true

        #expect(isEntryMenu(pane.keyboardContextMenu()))
        #expect(pane.selectionTargets().map(\.name) == ["b.txt"])
    }

    @Test("in an empty folder the menu is the folder's own")
    func emptyFolder() {
        let hosted = windowedPane(showing: [], at: .local("/tmp/probe"))
        let pane = hosted.pane

        let menu = pane.keyboardContextMenu()
        #expect(!isEntryMenu(menu))
        #expect(folderShown(by: menu) == .local("/tmp/probe"))
    }

    // MARK: - The wiring

    /// The menu bar is the only dispatch path for a chord a user binds (docs/NOTES.md ▸ Key
    /// equivalents), so the File menu has to carry the item, not just the palette.
    @Test("the File menu carries Show Context Menu, and it is held back from a field editor")
    func wiring() throws {
        let selector = #selector(PanelViewController.showContextMenu(_:))
        #expect(CommandBinding.selector(for: "file.contextMenu") == selector)
        let items = MainMenuBuilder.build().items
            .flatMap { item in [item] + (item.submenu?.items ?? []) }
        let item = try #require(items.first { $0.action == selector })
        #expect(item.keyEquivalent.isEmpty)

        let hosted = windowedPane(showing: rows, at: .local("/tmp/probe"))
        let pane = hosted.pane
        pane.focusTable()
        #expect(pane.validateMenuItem(item))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        pane.view.addSubview(field)
        defer { field.removeFromSuperview() }
        #expect(hosted.window.makeFirstResponder(field))
        #expect(!pane.validateMenuItem(item))
    }

    // MARK: - Closing

    /// The closer is what makes a second tap of ⌥ put the menu away (`OptionTapMenuCloser`); what it
    /// decides from its samples is `PolledModifierTap`'s and is pinned in the core.
    @Test("every context menu closes on a tap of ⌥: a right-click's, the keyboard's, the Trash's")
    func everyMenuHasTheCloser() {
        let hosted = windowedPane(showing: rows, at: .local("/tmp/probe"))
        let pane = hosted.pane
        let closer = OptionTapMenuCloser.shared
        #expect(pane.contextMenu(forRow: pane.row(forEntryIndex: 0)).delegate === closer)
        #expect(pane.contextMenu(forRow: -1).delegate === closer)
        #expect(pane.keyboardContextMenu().delegate === closer)

        let trashed = Handoff.local(NSHomeDirectory() + "/.Trash/old.txt")
        let trash = windowedPane(showing: [trashed], at: VFSPath(backend: .trash, path: "/Trash"))
        #expect(trash.pane.contextMenu(forRow: trash.pane.row(forEntryIndex: 0)).delegate === closer)
        #expect(trash.pane.contextMenu(forRow: -1).delegate === closer)
    }

    /// Found live: ⌥ held for a right-click is pressed where the monitor sees it and let go inside
    /// the menu, where it does not. The menu's closing starts the recognizer again from the
    /// keyboard, which holds nothing in a test host.
    @Test("a menu closing clears a ⌥ whose release the menu kept from the app")
    func closingClearsAStaleOption() throws {
        OptionTapMenu.resetFromKeyboard()
        #expect(try !OptionTapMenu.handle(flags(.option, at: 1.0)))
        OptionTapMenuCloser.shared.menuDidClose(NSMenu())

        #expect(try !OptionTapMenu.handle(flags(.option, at: 2.0)))
        #expect(try OptionTapMenu.handle(flags([], at: 2.1)))
    }
}
