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
            keywords: ["compare", "diff", "contents", "filemerge", "kaleidoscope", "bbedit"],
            // ⌥F3 as the sibling of F3 "View": F3 looks at the file under the cursor, ⌥F3 looks at
            // it *against* the other pane's. Free on both presets (stock leaves F3/F4 unbound;
            // the Total Commander preset takes bare F3 for Quick Look, not ⌥F3).
            shortcut: CommandShortcut(key: "F3", modifiers: [.function, .option])
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
            // ⌃T next to ⌃D's favorites and ⌃Q's quick view — the control layer is where this app's
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
        ),
        Command(
            id: "file.putBack",
            title: "Put Back",
            category: .file,
            keywords: ["restore", "undelete", "trash", "recover", "original", "undo delete"]
            // No shortcut: it applies in exactly one place — a Trash listing — and every key worth
            // taking for it already means something everywhere else. Finder's ⌘⌫ is "move to
            // Trash" on the rest of the Mac, which is the opposite of this.
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
