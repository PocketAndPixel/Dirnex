import Foundation

/// The key scheme joining `DirnexCore`'s registries to the app's string catalog.
///
/// The core stays resource-free on purpose: it ships no `.xcstrings`, declares no
/// `defaultLocalization`, and its English `title`/`label`/`keywords` are the *fallback*, not the
/// presentation. The app looks each one up by the key built here and falls back to the core's
/// English when a translation is missing — so `swift test` stays hermetic and no catalog test ever
/// has to assert against translated output or pin a locale.
///
/// The load-bearing consequence: **a `Command.id` is a translation key**. Renaming one orphans its
/// translations in every language, exactly as `Command.id`'s own doc comment already promised
/// ("never localized, never changes"). `CommandCatalogTests` pins the id list for that reason.
public enum LocalizationKey {
    /// The command's menu/palette title, e.g. `command.file.copy.title`.
    public static func commandTitle(_ commandID: String) -> String {
        "command.\(commandID).title"
    }

    /// The command's extra palette search terms, e.g. `command.file.copy.keywords`.
    ///
    /// A string catalog value is a string, not a list, so the translated terms are written as one
    /// comma-separated value ("копировать, дублировать") and split by ``splitKeywords(_:)``. The
    /// translated terms are *added* to the core's English ones rather than replacing them, so a
    /// Russian user can still reach a command by typing "copy".
    public static func commandKeywords(_ commandID: String) -> String {
        "command.\(commandID).keywords"
    }

    /// The palette group label and generated menu title, e.g. `commandCategory.file.title`.
    public static func commandCategory(_ category: CommandCategory) -> String {
        "commandCategory.\(category.rawValue).title"
    }

    /// The short caption printed on a function-bar button, e.g. `functionBar.file.copy.label`.
    ///
    /// Keyed by the slot's *command id*, not its function key: a user who moves Copy from F5 to F9
    /// should carry its caption with it, and a user script's slot has no catalog entry to inherit.
    public static func functionBarLabel(commandID: String) -> String {
        "functionBar.\(commandID).label"
    }

    /// Split a translated comma-separated keyword value into terms, dropping empties and
    /// surrounding whitespace. Tolerant on purpose — the value is typed by a translator, and a
    /// stray trailing comma should cost nothing.
    public static func splitKeywords(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
