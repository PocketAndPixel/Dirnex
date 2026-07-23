import AppIntents
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The App Intents automation surface (PLAN.md §M6 "Automation: AppleScript/Shortcuts verbs").
///
/// Same split as `ScriptingCommandsTests`: the *decisions* belong to `DirnexCore.Automation` and are
/// tested there, so what is left here is the app-side contract — the entity query Shortcuts drives
/// the picker with, and the generated `Metadata.appintents` bundle.
///
/// That bundle is the App Intents equivalent of the sdef's `<cocoa class>` strings, and it fails the
/// same silent way: the intents compile whatever happens, and if the metadata processor doesn't emit
/// them, or a phrase is malformed, the app simply never appears in Shortcuts with nothing to see at
/// build time. These tests read the emitted metadata back out of the built bundle so that regression
/// is loud.
@Suite("Automation intents")
struct AutomationIntentsTests {
    // MARK: - The entity query behind the Shortcuts picker

    @Test("the picker lists the whole command registry")
    func queryEnumeratesOperations() async throws {
        let operations = try await DirnexOperationQuery().allEntities()
        #expect(operations.count >= CommandCatalog.all.count)
        let copy = try #require(operations.first { $0.id == "file.copy" })
        // Asserted against the localized registry rather than against the English literals it used
        // to name. `xcodebuild test` runs these in the *app*, which honours whatever
        // `AppleLanguages` the developer's own `com.dirnex.Dirnex` domain carries — so pinning the
        // app to Russian to check a translation made this suite fail on display text that was never
        // what it was testing. What it is testing is that the Shortcuts entity draws its name and
        // subtitle from the registry at all.
        let expected = try #require(LocalizedCatalog.command(for: "file.copy"))
        #expect(copy.name == expected.title)
        // The subtitle that keeps two similar rows apart in the picker.
        #expect(copy.category == expected.category.localizedTitle)
    }

    @Test("typing in the picker fuzzy-searches, best match first")
    func querySearches() async throws {
        let matches = try await DirnexOperationQuery().entities(matching: "copy to other")
        #expect(matches.first?.id == "file.copy")
    }

    @Test("a saved shortcut's id resolves back to its operation")
    func queryResolvesSavedIdentifiers() async throws {
        let resolved = try await DirnexOperationQuery().entities(for: ["file.rename", "file.copy"])
        // Order is preserved, so a shortcut holding several ids gets them back as it asked.
        #expect(resolved.map(\.id) == ["file.rename", "file.copy"])
    }

    @Test("an id that no longer exists resolves to nothing rather than to something else")
    func queryDropsStaleIdentifiers() async throws {
        let resolved = try await DirnexOperationQuery().entities(for: ["userScript.gone forever"])
        #expect(resolved.isEmpty)
    }

    // MARK: - The generated metadata bundle

    @Test("every intent reaches Shortcuts as a discoverable action")
    func intentsAreExtracted() throws {
        let actions = try metadata()["actions"] as? [String: Any] ?? [:]
        for name in [
            "RevealInDirnexIntent",
            "CopySelectionInDirnexIntent",
            "RunDirnexOperationIntent"
        ] {
            let action = try #require(actions[name] as? [String: Any], "\(name) was not extracted")
            #expect(action["isDiscoverable"] as? Bool == true, "\(name) is hidden from Shortcuts")
            // Every verb acts on a visible panel, so none of them may run with the app closed.
            #expect(action["openAppWhenRun"] as? Bool == true, "\(name) does not open the app")
        }
    }

    @Test("the operation entity ships with the query that populates its picker")
    func entityIsExtractedWithItsQuery() throws {
        let entities = try metadata()["entities"] as? [String: Any] ?? [:]
        let entity = try #require(entities["DirnexOperation"] as? [String: Any])
        // Without a default query the parameter renders as an empty picker — the whole point lost.
        #expect(entity["defaultQueryIdentifier"] as? String == "Dirnex.DirnexOperationQuery")

        let queries = try metadata()["queries"] as? [String: Any] ?? [:]
        let query = try #require(queries["DirnexOperationQuery"] as? [String: Any])
        #expect(query["entityType"] as? String == "DirnexOperation")
        #expect(query["defaultQueryForEntity"] as? Bool == true)
    }

    @Test("the app shortcut's phrases all name the app, as App Intents requires")
    func appShortcutPhrasesAreWellFormed() throws {
        let shortcuts = try #require(try metadata()["autoShortcuts"] as? [[String: Any]])
        #expect(!shortcuts.isEmpty, "no App Shortcut was extracted — Spotlight will show nothing")
        for shortcut in shortcuts {
            let templates = shortcut["phraseTemplates"] as? [[String: Any]] ?? []
            #expect(!templates.isEmpty, "an App Shortcut with no phrase can never be invoked")
            for template in templates {
                let phrase = try #require(template["key"] as? String)
                // A phrase missing the app-name token is rejected at registration, silently.
                #expect(
                    phrase.contains("${applicationName}"),
                    "phrase \"\(phrase)\" does not name the app"
                )
            }
        }
    }

    /// The `Metadata.appintents` payload Xcode's extractor writes into the app bundle.
    private func metadata() throws -> [String: Any] {
        let bundle = Bundle(for: DirnexRevealScriptCommand.self)
        let url = try #require(
            bundle.url(
                forResource: "extract",
                withExtension: "actionsdata",
                subdirectory: "Metadata.appintents"
            ),
            "the app bundle carries no App Intents metadata"
        )
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try #require(json as? [String: Any])
    }
}
