// The Workspace and Window categories, in a companion file of their own so
// `CommandCatalogCategories.swift` stays under SwiftLint's `file_length`: Next Audio Track brought it
// to 500 (PLAN.md §M42 ▸ Sound tracks).
extension CommandCatalog {
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
        ),
        // The move pair takes ⌥ over the brackets that already mean history (⌘[ ⌘]) and switching
        // tabs (⇧⌘[ ⇧⌘]), which is also Xcode's chord for moving a line. ⌥ is told apart from the
        // bare chord whichever item the menu holds first (measured with `performKeyEquivalent`).
        Command(
            id: "window.moveTabLeft",
            title: "Move Tab Left",
            category: .window,
            keywords: ["tab", "reorder", "order", "rearrange"],
            shortcut: CommandShortcut(key: "[", modifiers: [.command, .option])
        ),
        Command(
            id: "window.moveTabRight",
            title: "Move Tab Right",
            category: .window,
            keywords: ["tab", "reorder", "order", "rearrange"],
            shortcut: CommandShortcut(key: "]", modifiers: [.command, .option])
        ),
        Command(
            id: "window.moveTabToOtherPanel",
            title: "Move Tab to Other Panel",
            category: .window,
            keywords: ["tab", "pane", "side", "opposite", "send", "transfer"],
            // ⇧⌘M, for Move. Nothing else here claims it, and the text system binds no ⌘ chord.
            shortcut: CommandShortcut(key: "m", modifiers: [.command, .shift])
        )
    ]
}
