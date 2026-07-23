import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The guard that keeps localization from rotting silently.
///
/// A `Command.id` doubles as a translation key (see `LocalizationKey`), which buys a resource-free
/// core and costs exactly one thing: nothing in the compiler notices when a command is added,
/// renamed, or removed and the string catalog is not. The failure is quiet in the worst way — the
/// English fallback renders, so an untranslated command looks *fine* in an English screenshot and
/// only a Russian speaker ever finds it.
///
/// These tests read the real compiled bundle, not the `.xcstrings` source, so they check what
/// actually ships.
@Suite("Localization coverage")
struct LocalizationCoverageTests {
    /// The languages the app must be complete in — every shipped language other than the source.
    private var translatedLanguages: [AppLanguage] {
        AppLanguages.all.filter { $0 != AppLanguages.english }
    }

    /// The bundle for one language, or `nil` when the app was built without it.
    private func bundle(for language: AppLanguage) throws -> Bundle {
        let path = try #require(
            Bundle.main.path(forResource: language.code, ofType: "lproj"),
            "the built app has no \(language.code).lproj — is \(language.code) in knownRegions?"
        )
        return try #require(Bundle(path: path))
    }

    /// Look `key` up in `bundle`, distinguishing "absent" from "translated to something".
    private func translation(_ key: String, in bundle: Bundle) -> String? {
        let sentinel = "\u{0}missing"
        let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }

    @Test("every shipped language is actually in the built bundle")
    func everyLanguageIsBuilt() throws {
        for language in AppLanguages.all {
            #expect(Bundle.main.localizations.contains(language.code), "missing \(language.code)")
        }
    }

    @Test("every command has a translated title in every shipped language")
    func everyCommandTitleIsTranslated() throws {
        for language in translatedLanguages {
            let bundle = try bundle(for: language)
            for command in CommandCatalog.all {
                let key = LocalizationKey.commandTitle(command.id)
                let value = translation(key, in: bundle)
                #expect(value != nil, "\(language.code): no title for \(command.id)")
                // A translation that is byte-identical to the English is almost always a key that
                // was copied in and never translated. Not universally true — "Dirnex" is the same
                // in every language — so this only fires for multi-word titles.
                if let value, command.title.contains(" ") {
                    #expect(
                        value != command.title,
                        "\(language.code): \(command.id) is still English"
                    )
                }
            }
        }
    }

    @Test("every category and function-bar caption is translated")
    func everyCategoryAndBarLabelIsTranslated() throws {
        for language in translatedLanguages {
            let bundle = try bundle(for: language)
            for category in CommandCategory.allCases {
                let key = LocalizationKey.commandCategory(category)
                #expect(translation(key, in: bundle) != nil, "\(language.code): no \(key)")
            }
            for slot in FunctionBar.defaultSlots {
                let key = LocalizationKey.functionBarLabel(commandID: slot.commandID)
                #expect(translation(key, in: bundle) != nil, "\(language.code): no \(key)")
            }
        }
    }

    @Test("every first-run tour screen has a translated title and body in every shipped language")
    func everyTourScreenIsTranslated() throws {
        for language in translatedLanguages {
            let bundle = try bundle(for: language)
            for screen in FirstRunTour.screens {
                let titleKey = LocalizationKey.tourTitle(screen.id)
                let bodyKey = LocalizationKey.tourBody(screen.id)
                #expect(translation(titleKey, in: bundle) != nil, "\(language.code): no \(titleKey)")
                #expect(translation(bodyKey, in: bundle) != nil, "\(language.code): no \(bodyKey)")
            }
        }
    }

    @Test("every sidebar section header is translated in every shipped language")
    func everySidebarSectionIsTranslated() throws {
        for language in translatedLanguages {
            let bundle = try bundle(for: language)
            for section in SidebarSection.allCases {
                let key = LocalizationKey.sidebarSection(section)
                let value = translation(key, in: bundle)
                #expect(value != nil, "\(language.code): no \(key)")
                if let value {
                    #expect(value != section.title, "\(language.code): \(key) is still English")
                }
            }
        }
    }

    @Test("every Find-Files kind and age filter is translated in every shipped language")
    func everySearchFilterIsTranslated() throws {
        for language in translatedLanguages {
            let bundle = try bundle(for: language)
            for kind in SearchKind.allCases {
                let key = LocalizationKey.searchKind(kind)
                let value = translation(key, in: bundle)
                #expect(value != nil, "\(language.code): no \(key)")
                if let value { #expect(
                    value != kind.title,
                    "\(language.code): \(key) is still English"
                ) }
            }
            for age in SearchAge.allCases {
                let key = LocalizationKey.searchAge(age)
                let value = translation(key, in: bundle)
                #expect(value != nil, "\(language.code): no \(key)")
                if let value { #expect(
                    value != age.title,
                    "\(language.code): \(key) is still English"
                ) }
            }
        }
    }

    @Test("every Finder tag colour name is translated in every shipped language")
    func everyTagColorIsTranslated() throws {
        for language in translatedLanguages {
            let bundle = try bundle(for: language)
            for color in FinderTagColor.allCases {
                let key = LocalizationKey.tagColor(color)
                let value = translation(key, in: bundle)
                #expect(value != nil, "\(language.code): no \(key)")
                // "No Colour" → "Без цвета" and the rest all differ from English; the colour
                // names are single words but none coincides across en/ru.
                if let value { #expect(
                    value != color.title,
                    "\(language.code): \(key) is still English"
                ) }
            }
        }
    }

    @Test("every undo/redo action label is translated in every shipped language")
    func everyUndoActionLabelIsTranslated() throws {
        for language in translatedLanguages {
            let bundle = try bundle(for: language)
            for label in UndoActionLabel.allCases {
                let key = LocalizationKey.undoActionLabel(label)
                let value = translation(key, in: bundle)
                #expect(value != nil, "\(language.code): no \(key)")
                // None of the labels coincide across en/ru, so a byte-identical value is a
                // copied-in key that was never translated (the "Undo Move" that only a Russian
                // speaker ever finds).
                if let value {
                    #expect(value != label.title, "\(language.code): \(key) is still English")
                }
            }
        }
    }

    @Test("a translated command keeps its English keywords searchable alongside the new ones")
    func keywordsAreAdditive() {
        // The palette is the one place a translation could *remove* a user's ability to find
        // something: replacing "copy" with "копировать" would break every English habit and every
        // instruction written in English docs.
        let copy = LocalizedCatalog.command(for: "file.copy")
        let keywords = copy?.keywords ?? []
        #expect(keywords.contains("duplicate"))
        #expect(
            copy?.id == "file.copy",
            "the id must survive localization — it is the persistence key"
        )
    }

    @Test("localizing never drops or reorders the registry")
    func catalogShapeIsPreserved() {
        #expect(LocalizedCatalog.all.map(\.id) == CommandCatalog.all.map(\.id))
        for command in LocalizedCatalog.all {
            #expect(!command.title.isEmpty)
            // A raw key leaking to the UI is the specific failure `L10n`'s sentinel exists to
            // prevent; it would look like "command.file.copy.title" in the menu bar.
            #expect(!command.title.hasPrefix("command."), "raw key leaked as a title: \(command.id)")
        }
    }

    @Test("an unknown command passes through localization unchanged")
    func unknownCommandKeepsItsOwnStrings() {
        // User scripts build `Command`s outside the registry; they are named by the user and must
        // not be looked up, blanked, or renamed.
        let script = Command(
            id: "userScript.42",
            title: "Мой скрипт",
            category: .file,
            keywords: ["custom"]
        )
        let localized = LocalizedCatalog.localized(script)
        #expect(localized.title == "Мой скрипт")
        #expect(localized.keywords == ["custom"])
    }
}
