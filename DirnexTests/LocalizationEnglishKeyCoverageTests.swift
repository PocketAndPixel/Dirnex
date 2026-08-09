import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Reading one shipped language's compiled `.lproj`, shared by both localization suites.
///
/// Split out when `LocalizationCoverageTests` hit `type_body_length`: that suite checks the keys
/// the app *owns* — `Command.id` and its symbolic relatives, where a rename orphans a translation
/// — and this file checks the other kind, a string keyed by its own English text. The two fail for
/// opposite reasons, which is why they are separate suites rather than one longer one.
enum LocalizedBundles {
    /// The languages the app must be complete in — every shipped language other than the source.
    static var translated: [AppLanguage] {
        AppLanguages.all.filter { $0 != AppLanguages.english }
    }

    /// The bundle for one language, or a failure naming the language the build is missing.
    static func bundle(for language: AppLanguage) throws -> Bundle {
        let path = try #require(
            Bundle.main.path(forResource: language.code, ofType: "lproj"),
            "the built app has no \(language.code).lproj — is \(language.code) in knownRegions?"
        )
        return try #require(Bundle(path: path))
    }

    /// Look `key` up in `bundle`, distinguishing "absent" from "translated to something".
    static func translation(_ key: String, in bundle: Bundle) -> String? {
        let sentinel = "\u{0}missing"
        let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }
}

/// The guard over the strings keyed by their **English text** rather than by a symbolic id.
///
/// This is the half of the localization design nothing else can see. `String(localized: "Roomy")`
/// and every SwiftUI literal are keyed by the text itself, so a key the compiler extracts but the
/// catalog never receives compiles to *itself* — the string renders in English inside a fully
/// translated build, with no error, no log line, and a perfect English screenshot. Twenty-six of
/// them shipped that way across M14–M18 before anyone looked.
///
/// `scripts/check_localization_keys.py` is the general answer: it diffs the compiler's own
/// `.stringsdata` against the catalogs, so it sees *every* such key and runs in CI right after the
/// app build. What it cannot do is run in this suite, which has no access to a build directory —
/// so the enums below, the ones that can grow a case, are pinned here as well. A new `RowDensity`
/// arrives with no catalog entry and, without this, no other signal at all.
@Suite("Localization coverage — English-text keys")
struct LocalizationEnglishKeyCoverageTests {
    /// The English text each Settings-picker case is keyed by.
    ///
    /// Spelled out rather than read from `title`, because `title` is what the *running* language
    /// resolves to and the test target inherits whatever `AppleLanguages` the developer pinned
    /// Dirnex to — asking a Russian build for its key hands back the Russian. The tables are driven
    /// by `allCases` below, so a case added without one fails rather than going unchecked, and
    /// `keysMatchTheirTitles` is what keeps them from drifting off the strings that are displayed.
    private let rowDensityKeys: [RowDensity: String] = [
        .compact: "Compact", .regular: "Regular", .roomy: "Roomy"
    ]
    private let sizeVizKeys: [SizeVizDisplayMode: String] = [
        .bar: "Progress bar", .percentage: "Percentage", .both: "Both"
    ]

    /// The densities a language genuinely spells the English way, by language code.
    ///
    /// "Compact" is the ordinary French and Dutch word, so demanding a difference here would buy
    /// a translation written for the test rather than for the user — the same carve-out the tag
    /// colours make for German and French "Orange". The check is kept rather than dropped because
    /// the other two carry real translations in every language, and a "Roomy" left standing in a
    /// French build is precisely what this suite exists to catch.
    private let densitiesThatCoincideWithEnglish: [String: Set<String>] = [
        "fr": ["Compact"],
        "nl": ["Compact"]
    ]

    @Test("every row density is translated in every shipped language")
    func everyRowDensityIsTranslated() throws {
        for language in LocalizedBundles.translated {
            let bundle = try LocalizedBundles.bundle(for: language)
            for density in RowDensity.allCases {
                let key = try #require(rowDensityKeys[density], "no English key for .\(density.id)")
                let value = LocalizedBundles.translation(key, in: bundle)
                #expect(value != nil, "\(language.code): no title for row density .\(density.id)")
                let coincides = densitiesThatCoincideWithEnglish[language.code]?
                    .contains(key) ?? false
                if let value, !coincides {
                    #expect(value != key, "\(language.code): “\(key)” is still English")
                }
            }
        }
    }

    @Test("every size-viz display mode is translated in every shipped language")
    func everySizeVizModeIsTranslated() throws {
        for language in LocalizedBundles.translated {
            let bundle = try LocalizedBundles.bundle(for: language)
            for mode in SizeVizDisplayMode.allCases {
                let key = try #require(sizeVizKeys[mode], "no English key for .\(mode.id)")
                #expect(
                    LocalizedBundles.translation(key, in: bundle) != nil,
                    "\(language.code): no title for size-viz .\(mode.id)"
                )
                // No still-English check: "Percentage" is genuinely itself in Dutch, the same
                // one-word coincidence the archive formats and command titles carve out.
            }
        }
    }

    @Test("the pickers really are keyed by the English text these tables spell out")
    func keysMatchTheirTitles() {
        // The tables above are a second copy of a string that lives in `RowDensity.title`, so they
        // can drift from it — and a drifted key would make the tests above check a string nothing
        // displays, passing while the picker is untranslated. Under an English build the two must
        // agree; under any other, `title` is already translated and there is nothing to compare,
        // which is exactly when this is skipped rather than made to fail on a Russian machine.
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true else { return }
        for density in RowDensity.allCases {
            #expect(rowDensityKeys[density] == density.title)
        }
        for mode in SizeVizDisplayMode.allCases {
            #expect(sizeVizKeys[mode] == mode.title)
        }
    }
}
