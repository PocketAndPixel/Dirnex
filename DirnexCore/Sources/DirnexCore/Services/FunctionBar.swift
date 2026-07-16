import Foundation

/// One button in the Total-Commander-style function-key bar (PLAN.md §M6): a function key,
/// the short caption printed on the button, and the registry command it dispatches. Kept in
/// `DirnexCore` — data, not AppKit — so the default layout is unit-tested and a later
/// user-configurable bar (and a user script's optional F-key binding) is a change to data
/// rather than to view wiring, exactly like `CommandShortcut` and `FunctionBarSlot`'s
/// `commandID` twin over in `CommandCatalog`.
public struct FunctionBarSlot: Sendable, Equatable, Hashable, Codable {
    /// The function key this button represents (e.g. 5 → F5). Drives both the printed key token
    /// and, for a slot whose command has no menu equivalent, the key that fires it through the
    /// pane's key handler.
    public let functionKey: Int
    /// The short caption printed beside the key ("Copy"), deliberately terser than the command's
    /// full menu title ("Copy to Other Panel") so the row of buttons stays compact — TC prints
    /// "Copy", not the whole verb phrase.
    public let label: String
    /// The `CommandCatalog` id the button dispatches ("file.copy"). The app joins this with its
    /// selector table (the same join the menu bar and ⌘K palette use), so a button and its
    /// menu-bar twin can never run different things.
    public let commandID: String

    public init(functionKey: Int, label: String, commandID: String) {
        self.functionKey = functionKey
        self.label = label
        self.commandID = commandID
    }

    /// The printed key token, e.g. "F5" — what the button shows and what a user reaches for.
    public var keyName: String { "F\(functionKey)" }
}

/// The function-key bar's layout (PLAN.md §M6 "user actions … surfaced in palette and F-key
/// bar"). Today this is a fixed built-in set; keeping it a value here (rather than hard-coding
/// buttons in the view) is what lets the bar grow a user-configurable layout and a user
/// script's optional F-key binding without touching AppKit.
public enum FunctionBar {
    /// The built-in bar: Rename and View plus the four core file operations, in Total
    /// Commander's key order. Every slot names a real `CommandCatalog` command (a test pins
    /// that). F2/F5–F8 already carry a bare-function-key menu shortcut, so pressing those keys
    /// fires the command through the menu before it ever reaches the pane; F3 (Quick Look) has
    /// no menu equivalent — it fires through the pane's key handler, which is why the bar is the
    /// natural home for *any* function key that isn't otherwise bound (a user script's F-key
    /// binding included).
    public static let defaultSlots: [FunctionBarSlot] = [
        FunctionBarSlot(functionKey: 2, label: "Rename", commandID: "file.rename"),
        FunctionBarSlot(functionKey: 3, label: "View", commandID: "view.quickLook"),
        FunctionBarSlot(functionKey: 5, label: "Copy", commandID: "file.copy"),
        FunctionBarSlot(functionKey: 6, label: "Move", commandID: "file.move"),
        FunctionBarSlot(functionKey: 7, label: "NewFolder", commandID: "file.newFolder"),
        FunctionBarSlot(functionKey: 8, label: "Delete", commandID: "file.trash")
    ]

    /// The slot bound to function key `number`, or `nil` when nothing is — the pane's key
    /// handler uses this to turn an unhandled F-key press into its command. Returns `nil` for an
    /// unmapped key (e.g. F4) so the press falls through untouched.
    public static func slot(forFunctionKey number: Int) -> FunctionBarSlot? {
        defaultSlots.first { $0.functionKey == number }
    }
}
