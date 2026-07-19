import AppIntents
import DirnexCore

// The App Intents automation surface (PLAN.md §M6 "Automation: AppleScript/Shortcuts verbs") — the
// Shortcuts half of the same three verbs `Dirnex.sdef` exposes to AppleScript. Same decisions
// (`DirnexCore.Automation`), same dispatch (`BrowserWindowController.runCommand(id:)`), same window
// lookup (`Scripting.activeWindow`); only the door differs. Intents live in the app bundle, so
// Shortcuts, Spotlight, and the Shortcuts menu bar item all find them with no extension target.
//
// Each `perform()` is `@MainActor` — the window work needs it, and an async intent may be isolated
// to it directly, which is why these read straightforwardly where the Apple-event handlers next door
// have to go through `MainActor.assumeIsolated`.
//
// All three set `openAppWhenRun`: every verb acts on a *visible panel*, so running one from a
// background Shortcut with Dirnex closed should launch it rather than fail.

/// Shortcuts' "Reveal in Dirnex" — the `reveal` verb, taking a real file instead of a typed path.
struct RevealInDirnexIntent: AppIntent {
    static let title: LocalizedStringResource = "Reveal in Dirnex"
    static let description = IntentDescription(
        "Brings Dirnex's active panel to a file or folder and selects it, like Finder's Reveal.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun = true

    /// A file *reference*, so this action chains off Finder's "Get Selected Files", a Files picker,
    /// or any action that yields a file — the ergonomic win over AppleScript's path string.
    @Parameter(title: "File", description: "The file or folder to reveal.")
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Reveal \(\.$file) in Dirnex")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // A file can arrive as raw data with no location on disk (a Shortcuts-generated file, say),
        // and there is nothing to reveal in that case. Dirnex is unsandboxed, so a file that *does*
        // have a location keeps its real one — no security-scoped copy to chase.
        guard let url = file.fileURL else { throw DirnexIntentError.notOnDisk }
        guard let target = AutomationReveal.target(forPOSIXPath: url.path(percentEncoded: false))
        else {
            throw DirnexIntentError.notRevealable(url.lastPathComponent)
        }
        guard let window = Scripting.activeWindow else { throw DirnexIntentError.noWindow }
        window.reveal(target)
        return .result()
    }
}

/// Shortcuts' "Copy Selection to Other Panel" — the `copy selection` verb (F5).
struct CopySelectionInDirnexIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Selection to Other Panel"
    static let description = IntentDescription(
        "Copies the active panel's selection to the other panel, as F5 does.",
        categoryName: "Files"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let window = Scripting.activeWindow else { throw DirnexIntentError.noWindow }
        guard window.runCommand(id: "file.copy") else {
            throw DirnexIntentError.couldNotRun("Copy to Other Panel")
        }
        return .result()
    }
}

/// Shortcuts' "Run Dirnex Operation" — the `run operation` verb, as a picker rather than a name.
struct RunDirnexOperationIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Dirnex Operation"
    static let description = IntentDescription(
        "Runs any Dirnex command or user script, chosen from a list.",
        categoryName: "Files"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Operation", description: "The Dirnex command or user script to run.")
    var operation: DirnexOperation

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$operation) in Dirnex")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let window = Scripting.activeWindow else { throw DirnexIntentError.noWindow }
        // The id came from the picker, so it was real when the shortcut was built; it can still
        // have gone stale since (a deleted user script), which `runCommand` reports as `false`.
        guard window.runCommand(id: operation.id) else {
            throw DirnexIntentError.couldNotRun(operation.name)
        }
        return .result()
    }
}

// MARK: - App Shortcuts

/// The intents Spotlight and the Shortcuts app offer without the user building a shortcut first.
///
/// Only the zero-parameter verb qualifies: an App Shortcut has to be runnable straight from a
/// phrase, and the other two can't act until the user has picked a file or an operation. Those two
/// remain full Shortcuts actions — they just aren't one-tap.
struct DirnexAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CopySelectionInDirnexIntent(),
            phrases: [
                "Copy the selection in \(.applicationName)",
                "\(.applicationName) copy selection"
            ],
            shortTitle: "Copy Selection",
            systemImageName: "doc.on.doc"
        )
    }
}

// MARK: - Errors

/// Why a Dirnex intent could not run. `CustomLocalizedStringResourceConvertible` is what puts a
/// readable sentence in the Shortcuts error banner instead of a bare failure — the App Intents
/// equivalent of the `scriptErrorString` the Apple-event handlers set.
enum DirnexIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noWindow
    case notOnDisk
    case notRevealable(String)
    case couldNotRun(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noWindow:
            return "\(Scripting.noWindowMessage)"
        case .notOnDisk:
            return "That file has no location on disk, so there is nothing to reveal."
        case let .notRevealable(name):
            return "“\(name)” is not a file Dirnex can reveal."
        case let .couldNotRun(name):
            return "“\(name)” could not be run."
        }
    }
}
