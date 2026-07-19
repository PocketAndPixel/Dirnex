import Foundation
import Testing

@testable import DirnexCore

@Suite("CommandCatalog")
struct CommandCatalogTests {
    @Test("every command has a unique, non-empty id and title")
    func idsAndTitlesAreWellFormed() {
        let commands = CommandCatalog.all
        #expect(!commands.isEmpty)
        for command in commands {
            #expect(!command.id.isEmpty)
            #expect(!command.title.isEmpty)
        }
        let ids = commands.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("the catalog carries the M2 file operations and the palette entry itself")
    func coversKnownCommands() {
        let ids = Set(CommandCatalog.all.map(\.id))
        for expected in ["file.copy", "file.move", "file.trash", "edit.undo", "view.commandPalette"] {
            #expect(ids.contains(expected))
        }
    }

    @Test("every category is represented so no menu builds empty")
    func everyCategoryHasCommands() {
        for category in CommandCategory.allCases {
            let count = CommandCatalog.all.filter { $0.category == category }.count
            #expect(count > 0, "category \(category) has no commands")
        }
    }

    @Test("the catalog carries the M3 per-panel history commands")
    func coversHistoryCommands() {
        let ids = Set(CommandCatalog.all.map(\.id))
        for expected in ["go.back", "go.forward", "go.history"] {
            #expect(ids.contains(expected))
        }
    }

    @Test("the catalog carries the M3 workspace commands")
    func coversWorkspaceCommands() {
        let workspace = CommandCatalog.all.filter { $0.category == .workspace }
        #expect(Set(workspace.map(\.id)) == ["workspace.list", "workspace.save"])
    }

    @Test("the catalog carries the clipboard copy/paste commands on ⌘C/⌘V/⌥⌘V")
    func coversClipboardCommands() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        #expect(byID["edit.copy"]?.shortcut == CommandShortcut(key: "c", modifiers: .command))
        #expect(byID["edit.paste"]?.shortcut == CommandShortcut(key: "v", modifiers: .command))
        #expect(
            byID["edit.pasteMove"]?.shortcut
                == CommandShortcut(key: "v", modifiers: [.command, .option])
        )
    }

    @Test("the clipboard shortcuts don't collide with any other command")
    func clipboardShortcutsAreConflictFree() {
        let bindings = KeyBindings()
        for id in ["edit.copy", "edit.paste", "edit.pasteMove"] {
            #expect(bindings.conflicts(for: id).isEmpty)
        }
    }

    @Test("the M4 multi-rename tool is a conflict-free File command on ⇧F2")
    func coversMultiRename() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let multiRename = byID["file.multiRename"]
        #expect(multiRename?.category == .file)
        #expect(multiRename?.shortcut == CommandShortcut(key: "F2", modifiers: [.function, .shift]))
        #expect(KeyBindings().conflicts(for: "file.multiRename").isEmpty)
    }

    @Test("the M5 synchronize-directories tool is a shortcut-free File command")
    func coversSyncDirectories() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let sync = byID["file.syncDirectories"]
        #expect(sync?.category == .file)
        // No default shortcut (reached via menu/palette), so it can never collide.
        #expect(sync?.shortcut == nil)
        #expect(KeyBindings().conflicts(for: "file.syncDirectories").isEmpty)
    }

    /// ⌥F3 reads as the sibling of F3 "View" — F3 looks at the file under the cursor, ⌥F3 looks at
    /// it against the other pane's — and has to stay clear of *both* presets, since the Total
    /// Commander one claims bare F3 for Quick Look.
    @Test("the M5 compare-by-contents tool is a conflict-free File command on ⌥F3")
    func coversCompareByContents() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let compare = byID["file.compareByContents"]
        #expect(compare?.category == .file)
        #expect(compare?.shortcut == CommandShortcut(key: "F3", modifiers: [.function, .option]))
        for preset in KeyBindings.Preset.allCases {
            #expect(
                KeyBindings.preset(preset).conflicts(for: "file.compareByContents").isEmpty,
                "⌥F3 collides under the \(preset) preset"
            )
        }
    }

    @Test("the M6 hand-off commands are shortcut-free File commands")
    func coversOpenWithAndShare() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        for id in ["file.openWith", "file.share"] {
            let command = byID[id]
            #expect(command?.category == .file)
            // No default shortcut (reached via menu/palette/right-click), so neither can collide.
            #expect(command?.shortcut == nil)
            #expect(KeyBindings().conflicts(for: id).isEmpty)
        }
    }

    @Test("the M7 Full Disk Access command is a shortcut-free Application command")
    func coversFullDiskAccess() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let fullDiskAccess = byID["app.fullDiskAccess"]
        #expect(fullDiskAccess?.category == .application)
        // No default shortcut (reached via the app menu / palette), so it can never collide.
        #expect(fullDiskAccess?.shortcut == nil)
        #expect(KeyBindings().conflicts(for: "app.fullDiskAccess").isEmpty)
    }

    @Test("the M7 first-run tour command is a shortcut-free Application command")
    func coversShowTour() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let tour = byID["app.showTour"]
        #expect(tour?.category == .application)
        // No default shortcut (reached via the app menu / palette), so it can never collide.
        #expect(tour?.shortcut == nil)
        #expect(KeyBindings().conflicts(for: "app.showTour").isEmpty)
    }

    @Test("the M6 manage-scripts command is a shortcut-free File command")
    func coversManageScripts() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let manage = byID["file.manageScripts"]
        #expect(manage?.category == .file)
        // No default shortcut (reached via menu/palette), so it can never collide.
        #expect(manage?.shortcut == nil)
        #expect(KeyBindings().conflicts(for: "file.manageScripts").isEmpty)
    }

    @Test("the M6 function-bar toggle is a shortcut-free View command")
    func coversFunctionBar() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let functionBar = byID["view.functionBar"]
        #expect(functionBar?.category == .view)
        // No default shortcut (a persistent-chrome toggle, like Show Tags), so it can't collide.
        #expect(functionBar?.shortcut == nil)
        #expect(KeyBindings().conflicts(for: "view.functionBar").isEmpty)
    }

    @Test("the M5 connect-to-server command is a shortcut-free navigation command")
    func coversConnectServer() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let connect = byID["go.connectServer"]
        #expect(connect?.category == .navigation)
        // No default shortcut (reached via menu/palette), so it can never collide.
        #expect(connect?.shortcut == nil)
        #expect(KeyBindings().conflicts(for: "go.connectServer").isEmpty)
    }

    @Test("the M4 pack tool is a conflict-free File command on ⌥F5")
    func coversPack() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let pack = byID["file.pack"]
        #expect(pack?.category == .file)
        #expect(pack?.shortcut == CommandShortcut(key: "F5", modifiers: [.function, .option]))
        #expect(KeyBindings().conflicts(for: "file.pack").isEmpty)
    }

    @Test("the show-hidden toggle is a conflict-free View command on ⇧⌘.")
    func coversShowHiddenToggle() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let toggle = byID["view.toggleHidden"]
        #expect(toggle?.category == .view)
        #expect(toggle?.shortcut == CommandShortcut(key: ".", modifiers: [.command, .shift]))
        #expect(KeyBindings().conflicts(for: "view.toggleHidden").isEmpty)
    }

    @Test("the M4 quick-view panel is a conflict-free View command on ⌃Q")
    func coversQuickViewPanel() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let quickView = byID["view.quickView"]
        #expect(quickView?.category == .view)
        #expect(quickView?.shortcut == CommandShortcut(key: "q", modifiers: .control))
        #expect(KeyBindings().conflicts(for: "view.quickView").isEmpty)
    }

    @Test("the M6 terminal drawer is a conflict-free View command on ⌃`")
    func coversTerminalDrawer() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let drawer = byID["view.terminal"]
        #expect(drawer?.category == .view)
        #expect(drawer?.shortcut == CommandShortcut(key: "`", modifiers: .control))
        #expect(KeyBindings().conflicts(for: "view.terminal").isEmpty)
    }

    /// The drawer's shortcut must stay off the ⌃-letter layer the app's own popups live on: those
    /// letters are the shell's (⌃D is EOF, ⌃Q is XON, ⌃T transposes), and the drawer is the one
    /// surface whose keystrokes belong to somebody else.
    @Test("the terminal drawer's shortcut is not a control key a shell would want")
    func terminalDrawerAvoidsShellControlKeys() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let drawer = byID["view.terminal"]
        #expect(drawer?.shortcut?.modifiers == .control)
        #expect(drawer?.shortcut?.key.first?.isLetter == false)
    }

    @Test("the M6 open-in-terminal command is a shortcut-free navigation command")
    func coversOpenInTerminal() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let open = byID["go.openInTerminal"]
        #expect(open?.category == .navigation)
        // No default shortcut (reached via menu/palette), so it can never collide.
        #expect(open?.shortcut == nil)
        #expect(KeyBindings().conflicts(for: "go.openInTerminal").isEmpty)
    }

    @Test("Select All is a conflict-free Select command on ⌘A")
    func coversSelectAll() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let selectAll = byID["select.all"]
        #expect(selectAll?.category == .selection)
        #expect(selectAll?.shortcut == CommandShortcut(key: "a", modifiers: .command))
        // ⌘A doubles as the text-field "select all" — it must not collide with any pane command.
        #expect(KeyBindings().conflicts(for: "select.all").isEmpty)
    }

    @Test("the M4 file search is a conflict-free Go command on ⌥F7")
    func coversFindFiles() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let search = byID["go.search"]
        #expect(search?.category == .navigation)
        #expect(search?.shortcut == CommandShortcut(key: "F7", modifiers: [.function, .option]))
        // ⌥F7 must not collide with plain F7 (New Folder) — the modifier set differs.
        #expect(KeyBindings().conflicts(for: "go.search").isEmpty)
    }

    @Test("the M4 saved-search command is a conflict-free Go command on ⌘S")
    func coversSaveSearch() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let save = byID["go.saveSearch"]
        #expect(save?.category == .navigation)
        // ⌘S saves the active search; distinct from ⌃⌘S (Show Sidebar), so no collision.
        #expect(save?.shortcut == CommandShortcut(key: "s", modifiers: .command))
        #expect(KeyBindings().conflicts(for: "go.saveSearch").isEmpty)
    }
}

@Suite("CommandShortcut display")
struct CommandShortcutTests {
    @Test("modifiers render in canonical ⌃⌥⇧⌘ order with an upper-cased letter")
    func canonicalOrder() {
        let shortcut = CommandShortcut(key: "s", modifiers: [.command, .control])
        #expect(shortcut.display == "⌃⌘S")
    }

    @Test("a function key keeps its name and never shows a fn glyph")
    func functionKeyDisplay() {
        #expect(CommandShortcut(key: "F5", modifiers: .function).display == "F5")
        #expect(CommandShortcut(key: "F8", modifiers: [.function, .shift]).display == "⇧F8")
    }

    @Test("the command arrow renders the glyph, not the fn layer")
    func arrowDisplay() {
        #expect(CommandShortcut(key: "↑", modifiers: [.command, .function]).display == "⌘↑")
    }

    @Test("literal punctuation keys pass through unchanged")
    func punctuationDisplay() {
        #expect(CommandShortcut(key: "[", modifiers: [.command, .shift]).display == "⇧⌘[")
    }

    @Test("the back/forward and history shortcuts render as expected")
    func historyShortcutDisplay() {
        #expect(CommandShortcut(key: "[", modifiers: .command).display == "⌘[")
        #expect(CommandShortcut(key: "]", modifiers: .command).display == "⌘]")
        #expect(CommandShortcut(key: "↓", modifiers: [.option, .function]).display == "⌥↓")
    }
}
