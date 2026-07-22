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
    /// The built-in bar: Rename, View and Edit plus the four core file operations, in Total
    /// Commander's key order. Every slot names a real `CommandCatalog` command (a test pins
    /// that). F2/F4–F8 already carry a bare-function-key menu shortcut, so pressing those keys
    /// fires the command through the menu before it ever reaches the pane; F3 (Quick Look) has
    /// no menu equivalent — it fires through the pane's key handler, which is why the bar is the
    /// natural home for *any* function key that isn't otherwise bound (a user script's F-key
    /// binding included).
    public static let defaultSlots: [FunctionBarSlot] = [
        FunctionBarSlot(functionKey: 2, label: "Rename", commandID: "file.rename"),
        FunctionBarSlot(functionKey: 3, label: "View", commandID: "view.quickLook"),
        FunctionBarSlot(functionKey: 4, label: "Edit", commandID: "file.edit"),
        FunctionBarSlot(functionKey: 5, label: "Copy", commandID: "file.copy"),
        FunctionBarSlot(functionKey: 6, label: "Move", commandID: "file.move"),
        FunctionBarSlot(functionKey: 7, label: "NewFolder", commandID: "file.newFolder"),
        FunctionBarSlot(functionKey: 8, label: "Delete", commandID: "file.trash")
    ]

    /// The slot bound to function key `number` within `slots`, or `nil` when nothing is — the
    /// pane's key handler uses this to turn an unhandled F-key press into its command. Returns
    /// `nil` for an unmapped key (e.g. F9 on a stock bar) so the press falls through untouched.
    ///
    /// `slots` is explicit rather than defaulting to `defaultSlots` on purpose: the caller that
    /// forgot to pass the merged bar would silently never fire a user script's key, which is a
    /// bug that looks exactly like "the feature doesn't work".
    public static func slot(forFunctionKey number: Int, in slots: [FunctionBarSlot]) -> FunctionBarSlot? {
        slots.first { $0.functionKey == number }
    }

    // MARK: - User-script bindings

    /// The keys an editor may offer, before anything is subtracted — the row of a normal keyboard.
    public static let functionKeyRange = 1...12

    /// Keys macOS consumes itself, before the frontmost app is ever asked. Bare **F11 is Show
    /// Desktop** (`com.apple.symbolichotkeys` id 36 — verified enabled with a bare `fn` mask on a
    /// stock system), so a script bound to it would run from its button and do nothing from the
    /// key. Every other F-key system hotkey (`⌃F1`–`⌃F8` keyboard navigation, `⌥⌘F5`
    /// accessibility) needs a modifier and so leaves the bare key alone.
    ///
    /// This is a *default*, not a reading of the live system — a user who turned Show Desktop off
    /// loses F11 for nothing, which is a key, against a silent no-op for everyone who didn't.
    public static let systemReservedFunctionKeys: Set<Int> = [11]

    /// The keys a user script must not take, under `bindings`.
    ///
    /// **Derived, never hard-coded**, from the two ways a key can already be spoken for:
    /// 1. A command whose effective shortcut *is* that bare F-key. This is the load-bearing one —
    ///    a menu key-equivalent is dispatched by AppKit **before** `keyDown` reaches the pane, so
    ///    a script on such a key would fire from its button and never from the key itself. The set
    ///    moves with the user: the Total Commander preset rebinds `view.quickLook` to bare F3 and
    ///    `file.rename` off bare F2, which is exactly why this reads `bindings` rather than the
    ///    catalog's defaults.
    /// 2. A key the built-in bar already prints, so a script can't quietly displace Copy or View.
    ///
    /// A modified shortcut (`⇧F2`, `⌥F5`) does *not* reserve the bare key — it isn't the same
    /// key-equivalent, and AppKit will pass the unmodified press through.
    public static func reservedFunctionKeys(bindings: KeyBindings = KeyBindings()) -> Set<Int> {
        var reserved = Set(defaultSlots.map(\.functionKey))
        for command in CommandCatalog.all {
            guard let shortcut = bindings.shortcut(for: command.id),
                  let number = bareFunctionKey(shortcut) else { continue }
            reserved.insert(number)
        }
        return reserved
    }

    /// The keys a script can actually be bound to, in ascending order — what an editor offers.
    /// On a stock build: F1, F9, F10 and F12. (F4 left this set when it became "Edit" in §M11.)
    public static func assignableFunctionKeys(bindings: KeyBindings = KeyBindings()) -> [Int] {
        let reserved = reservedFunctionKeys(bindings: bindings)
        return functionKeyRange.filter {
            !reserved.contains($0) && !systemReservedFunctionKeys.contains($0)
        }
    }

    /// The scripts holding a function key that is no longer theirs to fire — what the app warns
    /// about on load, rather than letting the binding degrade quietly.
    ///
    /// The case this exists for is F4 (PLAN.md §M11): a key that was assignable in a shipped build
    /// and is "Edit" in the next one. Such a script keeps everything else and still runs from the
    /// palette, but its key now belongs to a command dispatched *before* the pane's key handler is
    /// ever asked — so pressing it silently does something else, which is exactly the failure a
    /// user cannot diagnose from where they are standing.
    ///
    /// Ordering follows `userScripts`, so a message lists them the way the organizer does.
    public static func displacedScripts(
        _ userScripts: [UserScript],
        bindings: KeyBindings = KeyBindings()
    ) -> [UserScript] {
        let assignable = Set(assignableFunctionKeys(bindings: bindings))
        return userScripts.filter { script in
            guard let key = script.functionKey else { return false }
            return !assignable.contains(key)
        }
    }

    /// The whole bar: the built-in slots plus a slot for every user script holding a usable key,
    /// in key order, so the buttons read left to right as the keyboard does.
    ///
    /// Scripts whose key is unassignable *right now* are skipped rather than dropped — see
    /// `UserScript.functionKey` for why the store is allowed to hold one. Two scripts on one key
    /// can't normally happen (`UserScripts` upholds that), so the de-duplication here is only for
    /// a hand-edited store; first in user order wins, matching every other tie-break.
    public static func slots(
        userScripts: [UserScript],
        bindings: KeyBindings = KeyBindings()
    ) -> [FunctionBarSlot] {
        let assignable = Set(assignableFunctionKeys(bindings: bindings))
        var claimed = Set<Int>()
        var result = defaultSlots
        for script in userScripts {
            guard let key = script.functionKey, assignable.contains(key),
                  claimed.insert(key).inserted else { continue }
            result.append(
                FunctionBarSlot(functionKey: key, label: script.name, commandID: script.commandID)
            )
        }
        return result.sorted { $0.functionKey < $1.functionKey }
    }

    /// The number in a bare-function-key shortcut ("F5" + exactly `fn` → 5), or `nil` for any
    /// other shortcut — a letter key, or a function key carrying a real modifier.
    private static func bareFunctionKey(_ shortcut: CommandShortcut) -> Int? {
        guard shortcut.modifiers == .function, shortcut.key.hasPrefix("F"),
              let number = Int(shortcut.key.dropFirst()) else { return nil }
        return number
    }
}
