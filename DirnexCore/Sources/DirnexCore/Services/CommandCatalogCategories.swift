import Foundation

// The View, Navigation, Workspace, Window, and Application categories live in this companion file so
// `CommandCatalog.swift` stays under SwiftLint's `type_body_length` *and* `file_length` limits — the
// M8 Focus Sidebar command was the entry that pushed the single file over 500 lines. `all`, in the
// main file, still composes these in with `file`/`edit`/`selection`; the arrays widen from `private`
// to `internal` only because Swift's `private` does not cross files.
extension CommandCatalog {
    // MARK: - View

    static let view: [Command] = [
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
            id: "view.focusSidebar",
            title: "Focus Sidebar",
            category: .view,
            keywords: [
                "places", "volumes", "favorites", "keyboard", "select", "navigate", "source list",
                "move focus"
            ],
            // ⌥⌘S, deliberately the sibling of ⌃⌘S (toggle): the app has no other spatial
            // focus-movement key, and a source list you cannot reach from the keyboard is a hole in
            // a keyboard-first app (PLAN.md §M8). Rebindable like every shortcut; the pane switches
            // with Tab, so the sidebar earns its own chord rather than joining that cycle and
            // surprising the two-pane muscle memory.
            shortcut: CommandShortcut(key: "s", modifiers: [.option, .command])
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
            // view, ⌃T tags, ⌃D favorites). No conflict with the terminal drawer's reasoning: that one
            // fled to ⌃` precisely because its keystrokes belong to a shell, and this mode's do not.
            shortcut: CommandShortcut(key: "b", modifiers: .control)
        ),
        Command(
            id: "view.gitAwareSizes",
            title: "Exclude Git-Ignored from Sizes",
            category: .view,
            keywords: [
                "git", "gitignore", "ignored", "ignore", "sizes", "size", "folder", "build",
                "node_modules", "artifacts", "source", "repo", "repository", "clean"
            ]
            // No shortcut: it changes what a number *means* rather than what is on screen, and a
            // stray keystroke silently restating every size in the column is not a mistake anyone
            // would connect to the key they hit. The menu and the palette are deliberate enough.
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
            // ⌃` rather than the ⌃-letter layer the app's own popups use (⌃T tags, ⌃D favorites,
            // ⌃Q quick view): every one of those letters means something to a shell — ⌃D is EOF,
            // ⌃Q is XON — and the drawer is the one surface where the user's keystrokes are meant
            // to belong to somebody else. ⌃` is VS Code's gesture for exactly this drawer, and no
            // shell wants it.
            shortcut: CommandShortcut(key: "`", modifiers: .control)
        )
    ]

    // MARK: - Go

    static let navigation: [Command] = [
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
            // `id` keeps its legacy `hotlist` spelling: it's the key user keybindings persist
            // under, and renaming it would silently drop any custom shortcut. Only the visible
            // title now reads "Favorites"; "hotlist" survives as a search keyword for the
            // Total Commander muscle memory that reaches for it.
            id: "go.hotlist",
            title: "Favorites…",
            category: .navigation,
            keywords: [
                "favorites",
                "bookmarks",
                "pinned",
                "jump",
                "ctrl d",
                "hotlist",
                "directory hotlist"
            ],
            shortcut: CommandShortcut(key: "d", modifiers: .control)
        ),
        Command(
            id: "go.addToHotlist",
            title: "Add to Favorites",
            category: .navigation,
            keywords: ["pin", "bookmark", "favorite", "hotlist"]
        )
    ]

    // MARK: - Workspace

    static let workspace: [Command] = [
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

    static let window: [Command] = [
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

    static let application: [Command] = [
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
            id: "app.checkForUpdates",
            title: "Check for Updates…",
            category: .application,
            keywords: ["update", "upgrade", "sparkle", "version", "release", "new"]
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
