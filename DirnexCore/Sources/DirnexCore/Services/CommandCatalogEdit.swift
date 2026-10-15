// The Edit and Select categories live in this companion file for the reason
// `CommandCatalogCategories.swift` does: `CommandCatalog.swift` sits at SwiftLint's `type_body_length`,
// and the File category is the one that keeps growing. `all` composes them in the same order as before.
extension CommandCatalog {
    // MARK: - Edit

    static let edit: [Command] = [
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

    static let selection: [Command] = [
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
