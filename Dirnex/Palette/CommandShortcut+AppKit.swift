import AppKit
import DirnexCore

/// Translates the registry's headless `CommandShortcut` into the two AppKit pieces an
/// `NSMenuItem` needs: a key-equivalent string and a modifier mask. Keeping this app-side
/// lets `DirnexCore` stay AppKit-free while the menu bar is still generated from the registry.
extension CommandShortcut {
    /// The `NSMenuItem.keyEquivalent` string — a function-key or arrow scalar for named keys,
    /// otherwise the literal character (lower-cased letters; punctuation as-is). Shift lives
    /// in the modifier mask, so the character itself is never upper-cased here.
    var keyEquivalent: String {
        if let scalar = Self.functionKeyScalar(key) ?? Self.arrowScalar(key) {
            return String(scalar)
        }
        return key.lowercased()
    }

    /// The AppKit modifier flags for this shortcut. `.function` maps to `.function` so the
    /// F-keys and arrow shortcuts match the mask the hand-built menu used before the registry.
    var modifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.function) { mask.insert(.function) }
        return mask
    }

    /// Map "F1"…"F35" onto the contiguous private-use scalars AppKit reserves for them
    /// (`NSF1FunctionKey` = 0xF704). `nil` for any non-"F<number>" token.
    private static func functionKeyScalar(_ key: String) -> UnicodeScalar? {
        guard key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...35).contains(number) else {
            return nil
        }
        return UnicodeScalar(NSF1FunctionKey + number - 1)
    }

    /// Map the arrow glyphs onto their function-key scalars (only ↑ is used today, for ⌘↑
    /// "Go Up", but the four are handled for completeness).
    private static func arrowScalar(_ key: String) -> UnicodeScalar? {
        switch key {
        case "↑": return UnicodeScalar(NSUpArrowFunctionKey)
        case "↓": return UnicodeScalar(NSDownArrowFunctionKey)
        case "←": return UnicodeScalar(NSLeftArrowFunctionKey)
        case "→": return UnicodeScalar(NSRightArrowFunctionKey)
        default: return nil
        }
    }
}

// MARK: - Recording

extension CommandShortcut {
    /// Build a shortcut from a captured key-down `event` (the Settings shortcut recorder), or
    /// `nil` when the combination isn't bindable: a bare character with no ⌘/⌃/⌥ is rejected
    /// so it can't shadow the panel's type-to-filter, and modifier-only / control-key presses
    /// (Return, Tab, Esc, Delete) produce no token. Named keys — the F-keys and the arrows —
    /// are bindable on their own and carry the `fn` layer, matching the catalog convention.
    ///
    /// Known limitation: a shifted-punctuation combo (e.g. ⇧2) records the *shifted* glyph as
    /// its key, since `charactersIgnoringModifiers` applies Shift; letters and the common
    /// F-key / ⌘-letter / arrow combinations record exactly.
    init?(event: NSEvent) {
        guard let token = Self.recordingToken(for: event) else { return nil }

        var modifiers: Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        if Self.isNamedKey(token) {
            modifiers.insert(.function)
        } else if modifiers.isDisjoint(with: [.command, .control, .option]) {
            return nil
        }
        self.init(key: token, modifiers: modifiers)
    }

    /// Whether `token` is a self-standing named key (an "F<n>" function key or an arrow glyph).
    private static func isNamedKey(_ token: String) -> Bool {
        if token.hasPrefix("F"), Int(token.dropFirst()) != nil { return true }
        return ["↑", "↓", "←", "→"].contains(token)
    }

    /// The registry key token for a key-down `event`: an "F<n>" name, an arrow glyph, or the
    /// (Shift-applied, letter-lowercased) character. `nil` for modifier-only / control keys.
    private static func recordingToken(for event: NSEvent) -> String? {
        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first else { return nil }
        let value = Int(scalar.value)

        if value >= NSF1FunctionKey, value <= NSF35FunctionKey {
            return "F\(value - NSF1FunctionKey + 1)"
        }
        switch value {
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        default: break
        }

        // Reject control characters (Return, Tab, Esc, Delete) and modifier-only presses.
        guard scalar.value >= 0x20, !CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }
        if chars.count == 1, CharacterSet.uppercaseLetters.contains(scalar) {
            return chars.lowercased()
        }
        return chars
    }
}
