import Foundation

/// A keyboard shortcut described as data, independent of AppKit — a display token for the
/// key plus a set of modifier flags. The app translates it into an `NSMenuItem` key
/// equivalent when building the menu, and renders `display` in the command palette. Keeping
/// it headless lets the whole action registry (and its fuzzy search) be unit-tested, and
/// makes the M3 "rebindable shortcuts" item a change to data rather than to AppKit wiring.
///
/// `Codable` so a user's rebindings (`KeyBindings`) can be persisted as boring JSON, matching
/// the rest of the app's stores.
public struct CommandShortcut: Sendable, Equatable, Hashable, Codable {
    /// The modifier keys held with the shortcut. Rendered in the canonical macOS order
    /// (⌃⌥⇧⌘) regardless of insertion order.
    public struct Modifiers: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Encode as the bare raw `Int` (`{"modifiers": 5}`) rather than a wrapper object, so
        /// a persisted binding reads cleanly.
        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(Int.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
        /// The `fn` layer — carried by the F-keys and the arrow cluster. Never rendered as a
        /// glyph (macOS shows "F5" and "⌘↑", not a fn symbol); it exists so the app can set
        /// the matching key-equivalent modifier mask.
        public static let function = Modifiers(rawValue: 1 << 4)
    }

    /// The key as a display/identity token: a single character ("z", "t", "["), a named
    /// function key ("F5"), or an arrow glyph ("↑"). The app maps this onto the concrete
    /// key-equivalent scalar AppKit expects.
    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// A macOS-style display string, e.g. "⌘Z", "⇧F8", "⌃⌘S", "⌘↑". Modifier glyphs come
    /// first in the canonical ⌃⌥⇧⌘ order; the `fn` layer is never shown. A single-character
    /// letter key is upper-cased to match how the standard menus render.
    public var display: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += Self.displayKey(key)
        return result
    }

    /// Upper-case a single alphabetic key ("z" → "Z"); leave multi-character tokens
    /// ("F5", "↑", "[") untouched.
    private static func displayKey(_ key: String) -> String {
        guard key.count == 1, let scalar = key.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(scalar) else {
            return key
        }
        return key.uppercased()
    }
}

/// The menu/topic a command belongs to. Drives both the palette's grouping hints and the
/// menu bar the app generates from the registry.
public enum CommandCategory: String, Sendable, CaseIterable {
    case file
    case edit
    case selection
    case view
    case navigation
    case workspace
    case window
    case application

    /// The human-facing section name, used as the palette's group label and the menu title.
    public var title: String {
        switch self {
        case .file: return "File"
        case .edit: return "Edit"
        case .selection: return "Select"
        case .view: return "View"
        case .navigation: return "Go"
        case .workspace: return "Workspace"
        case .window: return "Window"
        case .application: return "Dirnex"
        }
    }
}

/// One discoverable action in the registry: a stable identity plus everything the palette
/// and menu need to present it — title, category, extra search keywords, and its default
/// shortcut. The registry is the single source of truth the app joins with AppKit selectors
/// (see the app's command bindings) so the menu bar and the Cmd+K palette never drift apart.
public struct Command: Sendable, Identifiable, Equatable {
    /// Stable, dotted identity (e.g. "file.copy"). Used as the persistence key for recents
    /// and, app-side, as the lookup into the selector table — never localized, never changes.
    public let id: String
    /// The user-facing label, matching the menu item ("Copy to Other Panel").
    public let title: String
    public let category: CommandCategory
    /// Extra terms the palette matches against beyond the title — synonyms and mnemonics
    /// ("duplicate", "f5") so a user's word finds the command even when the title doesn't
    /// contain it.
    public let keywords: [String]
    /// The default shortcut shown in the palette and set on the generated menu item; `nil`
    /// for commands whose only gesture lives in the table's key model (e.g. `*` invert).
    public let shortcut: CommandShortcut?

    public init(
        id: String,
        title: String,
        category: CommandCategory,
        keywords: [String] = [],
        shortcut: CommandShortcut? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.keywords = keywords
        self.shortcut = shortcut
    }
}
