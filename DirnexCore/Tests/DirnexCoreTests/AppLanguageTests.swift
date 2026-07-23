import Foundation
import Testing

@testable import DirnexCore

@Suite("AppLanguage")
struct AppLanguageTests {
    @Test("English is shipped, is first, and is the fallback")
    func englishIsTheBase() {
        #expect(AppLanguages.all.first == AppLanguages.english)
        #expect(AppLanguages.english.code == "en")
        #expect(AppLanguages.bestMatch(forPreferred: []) == AppLanguages.english)
        #expect(AppLanguages.bestMatch(forPreferred: ["xh-ZA", "tlh"]) == AppLanguages.english)
    }

    @Test("every shipped language has a unique code and a non-empty endonym")
    func shippedLanguagesAreWellFormed() {
        let codes = AppLanguages.all.map(\.code)
        #expect(Set(codes).count == codes.count)
        for language in AppLanguages.all {
            #expect(!language.code.isEmpty)
            #expect(!language.endonym.isEmpty)
        }
    }

    @Test("an endonym is written in its own language, not in English")
    func endonymsAreNotEnglish() {
        // The whole point of an endonym is that a user stranded in an unreadable UI can still find
        // their language. Pinning Russian's spelling is what keeps a future "Russian" from creeping
        // in as a well-meaning translation.
        let russian = AppLanguages.language(for: "ru")
        #expect(russian?.endonym == "Русский")
    }

    @Test("lookup by code is case-insensitive and rejects unshipped languages")
    func lookupByCode() {
        #expect(AppLanguages.language(for: "RU")?.code == "ru")
        #expect(AppLanguages.language(for: "ru") != nil)
        #expect(AppLanguages.language(for: "de") == nil)
        #expect(AppLanguages.language(for: "") == nil)
    }

    @Test("a regional tag matches its base language")
    func regionalTagMatchesBase() {
        #expect(AppLanguages.bestMatch(forPreferred: ["ru-RU"]).code == "ru")
        #expect(AppLanguages.bestMatch(forPreferred: ["en-GB"]).code == "en")
    }

    @Test("the first preferred tag that matches wins, however loosely")
    func earlierTagBeatsLaterTag() {
        // A user whose first choice is Russian gets Russian even though English sits behind it and
        // would match exactly — order of preference outranks tightness of match.
        #expect(AppLanguages.bestMatch(forPreferred: ["ru-RU", "en-US"]).code == "ru")
        #expect(AppLanguages.bestMatch(forPreferred: ["en-US", "ru-RU"]).code == "en")
        // An unshipped first choice is skipped rather than falling straight to English.
        #expect(AppLanguages.bestMatch(forPreferred: ["de-DE", "ru-RU"]).code == "ru")
    }

    @Test("a script-tagged language falls back through its primary subtag")
    func scriptTagFallsBackToPrimarySubtag() {
        // Not reachable today (no zh is shipped yet), so exercise the rule against the languages
        // that are: a made-up script subtag on Russian must still land on Russian rather than
        // dropping all the way to English.
        #expect(AppLanguages.bestMatch(forPreferred: ["ru-Cyrl-RU"]).code == "ru")
        #expect(AppLanguages.bestMatch(forPreferred: ["ru-Latn"]).code == "ru")
    }

    @Test("resolve honours a pin and otherwise follows the system")
    func resolveHonoursPreference() {
        let russian = AppLanguage(code: "ru", endonym: "Русский")
        #expect(AppLanguages.resolve(.explicit(russian), systemPreferred: ["en-US"]) == russian)
        #expect(AppLanguages.resolve(.system, systemPreferred: ["ru-RU"]).code == "ru")
        #expect(AppLanguages.resolve(.system, systemPreferred: []) == AppLanguages.english)
    }
}

@Suite("LocalizationKey")
struct LocalizationKeyTests {
    @Test("keys are built from the stable ids, not from display text")
    func keyShapes() {
        #expect(LocalizationKey.commandTitle("file.copy") == "command.file.copy.title")
        #expect(LocalizationKey.commandKeywords("file.copy") == "command.file.copy.keywords")
        #expect(LocalizationKey.commandCategory(.navigation) == "commandCategory.navigation.title")
        #expect(
            LocalizationKey.functionBarLabel(commandID: "file.copy") == "functionBar.file.copy.label"
        )
    }

    @Test("every command and category yields a distinct key")
    func keysAreUnique() {
        let titleKeys = CommandCatalog.all.map { LocalizationKey.commandTitle($0.id) }
        #expect(Set(titleKeys).count == titleKeys.count)
        let categoryKeys = CommandCategory.allCases.map(LocalizationKey.commandCategory)
        #expect(Set(categoryKeys).count == categoryKeys.count)
        // A title key can never collide with a keywords key for the same command.
        let keywordKeys = Set(CommandCatalog.all.map { LocalizationKey.commandKeywords($0.id) })
        #expect(keywordKeys.isDisjoint(with: titleKeys))
    }

    @Test("translated keywords split on commas and tolerate sloppy whitespace")
    func splitsKeywords() {
        #expect(
            LocalizationKey.splitKeywords("копировать, дублировать") == ["копировать", "дублировать"]
        )
        #expect(LocalizationKey.splitKeywords("  a ,, b ,  ") == ["a", "b"])
        #expect(LocalizationKey.splitKeywords("").isEmpty)
        #expect(LocalizationKey.splitKeywords("   ").isEmpty)
    }
}
