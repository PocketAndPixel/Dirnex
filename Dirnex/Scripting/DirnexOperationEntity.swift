import AppIntents
import DirnexCore

/// One Dirnex operation as Shortcuts sees it (PLAN.md §M6 "Automation: AppleScript/Shortcuts
/// verbs") — a catalog command or one of the user's own scripts, wrapped so the Shortcuts editor can
/// list it in a picker.
///
/// The AppleScript `run operation` verb takes a *typed name*, which is right for a scripting
/// language and wrong for Shortcuts: there, the user is clicking, not writing, so the action has to
/// offer the list. This entity is that list's element — `DirnexCore.AutomationOperation` supplies
/// the entries, this only dresses them for the picker.
struct DirnexOperation: AppEntity {
    /// The command id (`file.copy`) or user-script id (`userScript.To WebP`) — the same flat id
    /// space `BrowserWindowController.runCommand(id:)` dispatches, and what a saved shortcut stores.
    let id: String
    /// The menu title, or the script's name.
    let name: String
    /// The command's category ("File", "Go", …), shown as the picker row's subtitle so two
    /// similarly named operations are still tellable apart.
    let category: String

    init(_ command: Command) {
        id = command.id
        name = command.title
        category = command.category.title
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Dirnex Operation")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(category)")
    }

    static let defaultQuery = DirnexOperationQuery()
}

/// Feeds the Shortcuts picker for `DirnexOperation`.
///
/// Both halves are deliberate. `EnumerableEntityQuery` is what turns the parameter into a **browsable
/// dropdown** rather than a text field — the thing that makes the Shortcuts action self-documenting
/// where the AppleScript verb requires the user to already know a command's name. `EntityStringQuery`
/// adds the search field on top, backed by the palette's own fuzzy ranking, so a long registry stays
/// navigable by typing.
///
/// Every call reads the script store fresh (like the palette rebuild and the Scripts ▸ submenu do)
/// rather than caching: the user can add a script while the Shortcuts editor is open, and a stale
/// list would silently omit it.
struct DirnexOperationQuery: EnumerableEntityQuery, EntityStringQuery {
    /// The whole registry plus the user's scripts — the dropdown's contents.
    func allEntities() async throws -> [DirnexOperation] {
        AutomationOperation.all(userScripts: userScripts).map(DirnexOperation.init)
    }

    /// Fuzzy-ranked matches for what the user typed into the picker's search field.
    func entities(matching string: String) async throws -> [DirnexOperation] {
        AutomationOperation.search(string, userScripts: userScripts).map(DirnexOperation.init)
    }

    /// Re-resolve the ids a saved shortcut stored. Exact matching (see `AutomationOperation`): a
    /// shortcut pointing at a since-renamed script resolves to nothing and Shortcuts shows it as
    /// needing a value, which is far better than silently binding to a different operation.
    func entities(for identifiers: [String]) async throws -> [DirnexOperation] {
        AutomationOperation.operations(ids: identifiers, userScripts: userScripts).map(
            DirnexOperation.init
        )
    }

    /// The store read is nonisolated (plain `UserDefaults` JSON), so the query needs no actor hop.
    private var userScripts: [UserScript] { UserScriptStore.load().scripts }
}
