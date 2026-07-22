import Foundation

/// A language Dirnex ships strings for.
///
/// `code` is the tag as it appears in the built bundle (`en`, `ru`, and later `zh-Hans` and
/// friends) — the same spelling that goes into `AppleLanguages` to override the app's language.
///
/// `endonym` is the language's name *in itself* ("Русский", "日本語"), which is deliberately **not**
/// a localized string: a language picker lists every entry in its own language, so a user who has
/// landed in a UI they cannot read can still find their way out. That makes it data, not text, and
/// it belongs here beside the codes rather than in the app's string catalog.
public struct AppLanguage: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// The bundle/`AppleLanguages` tag, e.g. "en", "ru", "zh-Hans".
    public let code: String
    /// The language's name written in that language.
    public let endonym: String

    public var id: String { code }

    public init(code: String, endonym: String) {
        self.code = code
        self.endonym = endonym
    }

    /// The primary subtag, lower-cased — "zh" for "zh-Hans-CN". The unit of the loosest match
    /// `bestMatch(forPreferred:)` will make.
    var primarySubtag: String {
        (code.split(separator: "-").first.map(String.init) ?? code).lowercased()
    }
}

/// Whether the app follows the system's language or has been pinned to one in Settings.
///
/// `.system` is the default and is the *absence* of an override, not a language of its own — with
/// nothing pinned, ordinary bundle resolution picks the best match from the languages the app ships
/// and falls back to English, so auto-selection costs no code at all.
public enum LanguagePreference: Sendable, Equatable, Hashable {
    case system
    case explicit(AppLanguage)
}

/// The set of languages Dirnex ships, and the pure matching that turns the system's ordered
/// language preferences into one of them.
///
/// Adding a language is a one-line change here *plus* its translations in the app's
/// `Localizable.xcstrings` — never one without the other, or the picker offers an entry that
/// renders in English.
public enum AppLanguages {
    /// The development language and the fallback for everything unmatched. `Info.plist`'s
    /// development region and the string catalog's source language must agree with this.
    public static let english = AppLanguage(code: "en", endonym: "English")

    /// Every shipped language, in the order the Settings picker lists them: English first as the
    /// base, then the rest alphabetically by code.
    public static let all: [AppLanguage] = [
        english,
        AppLanguage(code: "ru", endonym: "Русский")
    ]

    /// The shipped language with `code`, matched case-insensitively, or `nil` when we don't ship it.
    public static func language(for code: String) -> AppLanguage? {
        all.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    /// The language to use for an ordered list of preferred tags — the shape of `AppleLanguages`
    /// (`["ru-RU", "en-US"]`) — falling back to `english` when nothing matches.
    ///
    /// Each preferred tag is tried in turn against three progressively looser rules before moving
    /// on to the next tag, so a user's *first* choice always beats a looser match on their second:
    ///
    /// 1. the whole tag (`pt-BR` finds a shipped `pt-BR`),
    /// 2. the tag with trailing subtags dropped one at a time (`zh-Hans-CN` → `zh-Hans` → `zh`),
    /// 3. primary-subtag equality (`zh-Hant-TW` finds a shipped `zh-Hans`).
    ///
    /// Rule 3 is the one that earns its keep for CJK: a Traditional-Chinese user is better served
    /// by Simplified than by English, which is what the OS does too, and without it a script tag we
    /// don't ship silently drops all the way to English.
    public static func bestMatch(forPreferred preferred: [String]) -> AppLanguage {
        for tag in preferred {
            var subtags = tag.split(separator: "-").map(String.init)
            while !subtags.isEmpty {
                if let match = language(for: subtags.joined(separator: "-")) { return match }
                subtags.removeLast()
            }
            guard let primary = tag.split(separator: "-").first?.lowercased() else { continue }
            if let match = all.first(where: { $0.primarySubtag == primary }) { return match }
        }
        return english
    }

    /// The language actually in force: the pinned one, or the best match for `systemPreferred`.
    ///
    /// `systemPreferred` must be read from the **global** defaults domain, not from
    /// `Locale.preferredLanguages` or `UserDefaults.standard` — both of those already reflect an
    /// `AppleLanguages` override written into the app's own domain, so asking them what the
    /// *system* prefers hands back the app's own answer.
    public static func resolve(
        _ preference: LanguagePreference,
        systemPreferred: [String]
    ) -> AppLanguage {
        switch preference {
        case .system: return bestMatch(forPreferred: systemPreferred)
        case let .explicit(language): return language
        }
    }
}
