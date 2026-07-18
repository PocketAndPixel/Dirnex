import Foundation

/// The registry of every discoverable action, in the order the palette lists them within a
/// category and the menu bar builds them. This is the single source of truth the app joins
/// with AppKit selectors to generate *both* the menu bar and the Cmd+K palette (PLAN.md §M3
/// "palette actions and menu bar generated from one action registry").
///
/// Shortcuts here are the *primary* binding shown to the user. Some commands also answer to
/// a second, Finder-style gesture wired directly in the table's key model (e.g. Move to
/// Trash on ⌘⌫ as well as F8) — those secondary bindings are an app concern and intentionally
/// not modeled here; the registry advertises the one canonical shortcut per command.
public enum CommandCatalog {
    /// Every command, grouped by category in presentation order. The app filters by category
    /// to build each menu and searches the whole list for the palette.
    public static let all: [Command] =
        file + edit + selection + view + navigation + workspace + window + application

    /// The command with `id`, or `nil` if unknown — the app's menu builder and palette look
    /// commands up by id to join them with AppKit selectors.
    public static func command(for id: String) -> Command? {
        all.first { $0.id == id }
    }

    // MARK: - File

    private static let file: [Command] = [
        Command(
            id: "file.newTab",
            title: "New Tab",
            category: .file,
            keywords: ["tab"],
            shortcut: CommandShortcut(key: "t", modifiers: .command)
        ),
        Command(
            id: "file.closeTab",
            title: "Close Tab",
            category: .file,
            keywords: ["tab"],
            shortcut: CommandShortcut(key: "w", modifiers: .command)
        ),
        Command(
            id: "file.openWith",
            title: "Open With",
            category: .file,
            keywords: ["open", "application", "app", "launch", "editor", "default"]
        ),
        Command(
            id: "file.share",
            title: "Share…",
            category: .file,
            keywords: ["share", "send", "airdrop", "mail", "message", "sheet"]
        ),
        Command(
            id: "file.copy",
            title: "Copy to Other Panel",
            category: .file,
            keywords: ["f5", "duplicate", "transfer"],
            shortcut: CommandShortcut(key: "F5", modifiers: .function)
        ),
        Command(
            id: "file.move",
            title: "Move to Other Panel",
            category: .file,
            keywords: ["f6", "transfer"],
            shortcut: CommandShortcut(key: "F6", modifiers: .function)
        ),
        Command(
            id: "file.pack",
            title: "Pack…",
            category: .file,
            keywords: ["compress", "archive", "zip", "tar", "alt+f5", "pack"],
            shortcut: CommandShortcut(key: "F5", modifiers: [.function, .option])
        ),
        Command(
            id: "file.syncDirectories",
            title: "Synchronize Directories…",
            category: .file,
            keywords: ["sync", "synchronize", "compare", "mirror", "diff", "directories", "folders"]
        ),
        Command(
            id: "file.compareByContents",
            title: "Compare By Contents…",
            category: .file,
            keywords: ["compare", "diff", "contents", "filemerge", "kaleidoscope", "bbedit"]
        ),
        Command(
            id: "file.manageScripts",
            title: "Manage Scripts…",
            category: .file,
            keywords: [
                "script", "scripts", "automation", "shell", "command", "action", "user", "custom"
            ]
        ),
        Command(
            id: "file.tags",
            title: "Tags…",
            category: .file,
            keywords: ["finder", "tag", "label", "colour", "color", "mark"],
            // ⌃T next to ⌃D's hotlist and ⌃Q's quick view — the control layer is where this app's
            // own popups live, and ⌘T is already New Tab.
            shortcut: CommandShortcut(key: "t", modifiers: .control)
        ),
        Command(
            id: "file.rename",
            title: "Rename…",
            category: .file,
            keywords: ["f2"],
            shortcut: CommandShortcut(key: "F2", modifiers: .function)
        ),
        Command(
            id: "file.multiRename",
            title: "Multi-Rename Tool…",
            category: .file,
            keywords: ["batch", "rename", "pattern", "counter", "regex", "mask"],
            shortcut: CommandShortcut(key: "F2", modifiers: [.function, .shift])
        ),
        Command(
            id: "file.newFolder",
            title: "New Folder",
            category: .file,
            keywords: ["f7", "directory", "mkdir", "create"],
            shortcut: CommandShortcut(key: "F7", modifiers: .function)
        ),
        Command(
            id: "file.trash",
            title: "Move to Trash",
            category: .file,
            keywords: ["f8", "delete", "remove"],
            shortcut: CommandShortcut(key: "F8", modifiers: .function)
        ),
        Command(
            id: "file.deletePermanently",
            title: "Delete Immediately…",
            category: .file,
            keywords: ["destroy", "remove", "erase"],
            shortcut: CommandShortcut(key: "F8", modifiers: [.function, .shift])
        )
    ]

    // MARK: - Edit

    private static let edit: [Command] = [
        Command(
            id: "edit.undo",
            title: "Undo",
            category: .edit,
            keywords: ["revert", "back"],
            shortcut: CommandShortcut(key: "z", modifiers: .command)
        ),
        Command(
            id: "edit.redo",
            title: "Redo",
            category: .edit,
            keywords: ["repeat", "forward", "again", "reapply"],
            shortcut: CommandShortcut(key: "z", modifiers: [.command, .shift])
        ),
        Command(
            id: "edit.copy",
            title: "Copy",
            category: .edit,
            keywords: ["clipboard", "duplicate", "pasteboard"],
            shortcut: CommandShortcut(key: "c", modifiers: .command)
        ),
        Command(
            id: "edit.paste",
            title: "Paste",
            category: .edit,
            keywords: ["clipboard", "pasteboard"],
            shortcut: CommandShortcut(key: "v", modifiers: .command)
        ),
        Command(
            id: "edit.pasteMove",
            title: "Move Items Here",
            category: .edit,
            keywords: ["clipboard", "paste", "cut", "pasteboard"],
            shortcut: CommandShortcut(key: "v", modifiers: [.command, .option])
        )
    ]

    // MARK: - Select

    private static let selection: [Command] = [
        Command(
            id: "select.all",
            title: "Select All",
            category: .selection,
            keywords: ["mark", "everything", "whole"],
            shortcut: CommandShortcut(key: "a", modifiers: .command)
        ),
        Command(
            id: "select.invert",
            title: "Invert Selection",
            category: .selection,
            keywords: ["toggle", "flip"]
        ),
        Command(
            id: "select.byPattern",
            title: "Select by Pattern…",
            category: .selection,
            keywords: ["wildcard", "glob", "mark"]
        ),
        Command(
            id: "select.unselectByPattern",
            title: "Unselect by Pattern…",
            category: .selection,
            keywords: ["wildcard", "glob", "deselect", "unmark"]
        )
    ]
}

// The View, Workspace, Window, and Application categories live in an extension so the main enum
// body stays under SwiftLint's `type_body_length` limit; `all` above still composes them in with
// the rest.
extension CommandCatalog {
    // MARK: - View

    private static let view: [Command] = [
        Command(
            id: "view.commandPalette",
            title: "Command Palette…",
            category: .view,
            keywords: ["actions", "commands", "search", "run"],
            shortcut: CommandShortcut(key: "k", modifiers: .command)
        ),
        Command(
            id: "view.toggleSidebar",
            title: "Show Sidebar",
            category: .view,
            keywords: ["places", "volumes", "hide"],
            shortcut: CommandShortcut(key: "s", modifiers: [.control, .command])
        ),
        Command(
            id: "view.toggleHidden",
            title: "Show Hidden Files",
            category: .view,
            keywords: ["dotfiles", "invisible", "dot", "hide", "reveal"],
            shortcut: CommandShortcut(key: ".", modifiers: [.command, .shift])
        ),
        Command(
            id: "view.toggleTags",
            title: "Show Tags",
            category: .view,
            keywords: ["finder", "tags", "labels", "colors", "colours", "dots", "column"]
        ),
        Command(
            id: "view.toggleSyncStatus",
            title: "Show Sync Status",
            category: .view,
            keywords: [
                "icloud", "cloud", "sync", "dropbox", "drive", "onedrive", "download",
                "downloaded", "offline", "placeholder", "badge"
            ]
        ),
        Command(
            id: "view.sizeVisualization",
            title: "Size Visualization",
            category: .view,
            keywords: [
                "ncdu", "bars", "graph", "chart", "disk", "usage", "space", "du", "biggest",
                "largest", "what is taking up"
            ],
            // ⌃B for "bars", on the ⌃-letter layer the app's own panel modes already use (⌃Q quick
            // view, ⌃T tags, ⌃D hotlist). No conflict with the terminal drawer's reasoning: that one
            // fled to ⌃` precisely because its keystrokes belong to a shell, and this mode's do not.
            shortcut: CommandShortcut(key: "b", modifiers: .control)
        ),
        Command(
            id: "view.functionBar",
            title: "Show Function Key Bar",
            category: .view,
            keywords: [
                "function", "keys", "f-keys", "fkeys", "f5", "f6", "f7", "f8", "toolbar", "bar",
                "buttons", "total commander", "tc"
            ]
            // No shortcut: it toggles a persistent chrome strip, like Show Tags — a menu/palette
            // action, not a gesture, and its F-keys already live on the buttons it shows.
        ),
        Command(
            id: "view.quickLook",
            title: "Quick Look",
            category: .view,
            keywords: ["preview", "peek"],
            shortcut: CommandShortcut(key: "y", modifiers: .command)
        ),
        Command(
            id: "view.quickView",
            title: "Quick View Panel",
            category: .view,
            keywords: ["preview", "peek", "pane", "inactive", "ctrl q"],
            shortcut: CommandShortcut(key: "q", modifiers: .control)
        ),
        Command(
            id: "view.terminal",
            title: "Terminal Drawer",
            category: .view,
            keywords: ["shell", "console", "command", "line", "zsh", "bash", "prompt", "drawer"],
            // ⌃` rather than the ⌃-letter layer the app's own popups use (⌃T tags, ⌃D hotlist,
            // ⌃Q quick view): every one of those letters means something to a shell — ⌃D is EOF,
            // ⌃Q is XON — and the drawer is the one surface where the user's keystrokes are meant
            // to belong to somebody else. ⌃` is VS Code's gesture for exactly this drawer, and no
            // shell wants it.
            shortcut: CommandShortcut(key: "`", modifiers: .control)
        )
    ]

    // MARK: - Go

    private static let navigation: [Command] = [
        Command(
            id: "go.editLocation",
            title: "Go to Location…",
            category: .navigation,
            keywords: ["path", "address", "type", "url", "jump", "frecency", "fuzzy", "recent"],
            shortcut: CommandShortcut(key: "l", modifiers: .command)
        ),
        Command(
            id: "go.search",
            title: "Find Files…",
            category: .navigation,
            keywords: ["search", "spotlight", "mdfind", "find", "locate", "filter", "alt f7"],
            shortcut: CommandShortcut(key: "F7", modifiers: [.function, .option])
        ),
        Command(
            id: "go.saveSearch",
            title: "Save Search…",
            category: .navigation,
            keywords: ["search", "saved", "smart", "folder", "bookmark", "sidebar"],
            // ⌘S is the natural "save" gesture; it only fires when the menu item is enabled —
            // i.e. an active search-results tab carrying a query (`canSaveCurrentSearch`) — so on
            // any other pane it's an inert no-op rather than a mis-save. (Distinct from ⌃⌘S,
            // Show Sidebar.)
            shortcut: CommandShortcut(key: "s", modifiers: .command)
        ),
        Command(
            id: "go.connectServer",
            title: "Connect to Server…",
            category: .navigation,
            keywords: [
                "sftp", "ssh", "smb", "share", "mount", "nas", "remote", "network",
                "server", "connect", "host"
            ]
        ),
        Command(
            id: "go.openInTerminal",
            title: "Open in Terminal",
            category: .navigation,
            keywords: [
                "terminal", "shell", "iterm", "wezterm", "console", "command", "prompt",
                "external", "app"
            ]
            // No shortcut: this is the *alternative* to the ⌃` drawer, for people who want their
            // own terminal with their own tabs and profile, so it's a palette/menu action rather
            // than a gesture. The title stays generic while `ExternalTerminal.preferred` picks the
            // app, so the registry keeps its one title for the menu bar and the palette alike.
        ),
        Command(
            id: "go.parent",
            title: "Go Up",
            category: .navigation,
            keywords: ["parent", "out"],
            shortcut: CommandShortcut(key: "↑", modifiers: [.command, .function])
        ),
        Command(
            id: "go.back",
            title: "Back",
            category: .navigation,
            keywords: ["history", "previous", "backward"],
            shortcut: CommandShortcut(key: "[", modifiers: .command)
        ),
        Command(
            id: "go.forward",
            title: "Forward",
            category: .navigation,
            keywords: ["history", "next"],
            shortcut: CommandShortcut(key: "]", modifiers: .command)
        ),
        Command(
            id: "go.history",
            title: "Directory History…",
            category: .navigation,
            keywords: ["recent", "visited", "trail", "alt down"],
            shortcut: CommandShortcut(key: "↓", modifiers: [.option, .function])
        ),
        Command(
            id: "go.hotlist",
            title: "Directory Hotlist…",
            category: .navigation,
            keywords: ["favorites", "bookmarks", "pinned", "jump", "ctrl d"],
            shortcut: CommandShortcut(key: "d", modifiers: .control)
        ),
        Command(
            id: "go.addToHotlist",
            title: "Add to Hotlist",
            category: .navigation,
            keywords: ["pin", "bookmark", "favorite", "hotlist"]
        )
    ]

    // MARK: - Workspace

    private static let workspace: [Command] = [
        Command(
            id: "workspace.list",
            title: "Workspaces…",
            category: .workspace,
            keywords: ["session", "switch", "restore", "open", "layout", "panes"]
        ),
        Command(
            id: "workspace.save",
            title: "Save Workspace…",
            category: .workspace,
            keywords: ["session", "snapshot", "store", "layout", "panes"]
        )
    ]

    // MARK: - Window

    private static let window: [Command] = [
        Command(
            id: "window.minimize",
            title: "Minimize",
            category: .window,
            shortcut: CommandShortcut(key: "m", modifiers: .command)
        ),
        Command(
            id: "window.close",
            title: "Close Window",
            category: .window,
            shortcut: CommandShortcut(key: "w", modifiers: [.command, .shift])
        ),
        Command(
            id: "window.previousTab",
            title: "Show Previous Tab",
            category: .window,
            keywords: ["tab"],
            shortcut: CommandShortcut(key: "[", modifiers: [.command, .shift])
        ),
        Command(
            id: "window.nextTab",
            title: "Show Next Tab",
            category: .window,
            keywords: ["tab"],
            shortcut: CommandShortcut(key: "]", modifiers: [.command, .shift])
        )
    ]

    // MARK: - Application

    private static let application: [Command] = [
        Command(
            id: "app.settings",
            title: "Settings…",
            category: .application,
            keywords: ["preferences", "options", "shortcuts", "config"],
            shortcut: CommandShortcut(key: ",", modifiers: .command)
        ),
        Command(
            id: "app.fullDiskAccess",
            title: "Full Disk Access…",
            category: .application,
            keywords: ["permission", "privacy", "security", "access", "disk", "grant", "onboarding"]
        ),
        Command(
            id: "app.showTour",
            title: "Welcome to Dirnex…",
            category: .application,
            keywords: ["tour", "welcome", "guide", "intro", "onboarding", "help", "getting started"]
        ),
        Command(
            id: "app.quit",
            title: "Quit Dirnex",
            category: .application,
            keywords: ["exit"],
            shortcut: CommandShortcut(key: "q", modifiers: .command)
        )
    ]
}
