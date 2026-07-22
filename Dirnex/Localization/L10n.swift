import Foundation

/// String lookup for keys the compiler cannot see.
///
/// Dirnex localizes in two deliberately different styles, and this helper serves only the second:
///
/// 1. **The app's own literals** use the English text as its own key —
///    `String(localized: "Reopen tabs from the previous session")`. Xcode extracts them into
///    `Localizable.xcstrings` at build time, a missing translation falls back to readable English
///    rather than to a key, and the diff at each call site is one wrapper. This is the style for the
///    strings in the AppKit and SwiftUI layers; it needs nothing from this file.
///
/// 2. **`DirnexCore`'s registry strings** are keyed symbolically by their stable id
///    (`command.file.copy.title`), because the core has no resources of its own and supplies the
///    English as data. Those keys are *built at runtime* from `Command.id`, so `String(localized:)`
///    cannot see them and cannot extract them — hence this direct bundle lookup, and hence their
///    catalog entries are written by hand (in Xcode's catalog editor) rather than appearing on
///    build. `LocalizationCoverageTests` is what replaces the compiler here: it reads the real
///    compiled `.lproj` and fails when a command, category or function-bar caption has no entry.
///
/// Everything in style 2 goes through `LocalizedCatalog`; this is its one primitive.
enum L10n {
    /// A sentinel no translator can produce, used to tell "translated to something" apart from
    /// "absent". `localizedString(forKey:value:table:)` has no other way to say which happened: it
    /// answers with the *key itself* when the value is empty and the key is missing, so a caller
    /// with nothing to fall back on would put `command.file.copy.title` in front of a user.
    private static let sentinel = "\u{0}dirnex.untranslated"

    /// The translation for `key`, or `nil` when the catalog has no entry for it.
    static func translation(_ key: String) -> String? {
        let value = Bundle.main.localizedString(forKey: key, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }

    /// The translation for `key`, or `fallback` when the catalog has no entry — where `fallback` is
    /// the English that `DirnexCore` carries as data.
    static func string(_ key: String, fallback: String) -> String {
        translation(key) ?? fallback
    }
}
