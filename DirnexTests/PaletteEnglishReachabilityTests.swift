import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The guard that keeps a translation from *removing* a way to reach a command.
///
/// Translating the palette is the one place localization can take capability away rather than add
/// it: a Russian or Ukrainian user typing on a Latin layout — the common case, not an edge case —
/// plus anyone following English docs or an English screenshot, reaches for the English word.
/// `LocalizedCatalog` therefore *adds* the translated keywords to the core's English ones and folds
/// the English **title** in beside them, because the title is the one string a translation replaces.
///
/// Every test here is language-agnostic on purpose: `xcodebuild test` runs in the app, which
/// inherits whatever `AppleLanguages` the developer has Dirnex pinned to (docs/NOTES.md), so a test
/// that only holds in English fails on the machine of the very person checking a translation.
@Suite("Palette English reachability")
struct PaletteEnglishReachabilityTests {
    @Test("a translated command keeps its English keywords searchable alongside the new ones")
    func keywordsAreAdditive() {
        // Replacing "duplicate" with "дублировать" would break every English habit and every
        // instruction written in English docs.
        let copy = LocalizedCatalog.command(for: "file.copy")
        let keywords = copy?.keywords ?? []
        #expect(keywords.contains("duplicate"))
        #expect(
            copy?.id == "file.copy",
            "the id must survive localization — it is the persistence key"
        )
    }

    @Test("every command stays findable by its English title, whatever the display language")
    func englishTitlesStaySearchable() {
        // The half `keywordsAreAdditive` does not cover, and the one that actually bit: a translated
        // title *replaces* the English one, so the most obvious term of all is the one that goes
        // missing. `file.copy`'s registry keywords are `f5, duplicate, transfer` — no "copy" — so in
        // a Russian build typing "copy" matched nothing at all until the title joined the terms.
        let palette = LocalizedCatalog.all
        for command in CommandCatalog.all {
            let matches = CommandMatcher.search(command.title, in: palette)
            #expect(
                matches.contains { $0.command.id == command.id },
                "\(command.id) is unreachable by its English title “\(command.title)”"
            )
        }
    }

    @Test("the English word a user types out of habit reaches its command")
    func englishHabitWordsReachTheirCommands() {
        // The reported symptom, pinned as itself: one bare English word per command, the word an
        // English-speaking habit reaches for. Each is a *prefix* of the English title and none of
        // them is a registry keyword, so this fails the moment the title stops being folded in.
        let habits = [
            ("file.copy", "copy"),
            ("file.move", "move"),
            ("file.rename", "rename"),
            ("file.newFolder", "new folder"),
            ("select.all", "select all")
        ]
        for (id, typed) in habits {
            let matches = CommandMatcher.search(typed, in: LocalizedCatalog.all)
            #expect(
                matches.contains { $0.command.id == id },
                "typing “\(typed)” does not reach \(id)"
            )
        }
    }

    @Test("a seeded template keeps its English keywords searchable alongside the translated ones")
    func templateKeywordsAreAdditive() {
        // Same reasoning one step further down: these keywords are copied into a script the user
        // then owns, so losing the English ones is permanent for that script.
        let template = try? #require(UserScriptTemplate.all.first)
        let script = template.map(LocalizedCatalog.script(for:))
        #expect(script?.keywords.contains("clipboard") == true)
        // The English *name* too, for the same reason commands fold theirs in: the seeded script is
        // saved under its translated name, so without this the user's own script becomes unfindable
        // by the name every English screenshot and doc calls it.
        let englishName = template?.title ?? ""
        let seeded = script?.keywords ?? []
        #expect(
            seeded.contains(englishName) || script?.name == englishName,
            "a seeded script must stay reachable by “\(englishName)”"
        )
        #expect(
            script?.command == template?.command,
            "the body is shell code and is never localized"
        )
    }
}
