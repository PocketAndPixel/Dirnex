import AppKit
import Foundation

/// The window an automation surface acts on (PLAN.md §M6 "Automation: AppleScript/Shortcuts verbs").
///
/// Shared by both doors into the app — the `NSScriptCommand` handlers in `ScriptingCommands.swift`
/// and the App Intents in `AutomationIntents.swift` — so "which window does a scripted verb hit"
/// has exactly one answer. The AppleScript-specific error numbers stay with the handlers; only the
/// target lookup is common ground.
enum Scripting {
    /// Shown when automation arrives with no window to act on — the app can be running with every
    /// browser window closed, and both surfaces report that the same way.
    ///
    /// A `LocalizedStringResource` rather than a `String` so it is declared (and extracted) exactly
    /// once and still serves both doors: App Intents take it as-is for the Shortcuts error banner,
    /// and the Apple-event handlers resolve it through `String(localized:)` for `scriptErrorString`.
    /// Interpolating a plain `String` into an intent's `LocalizedStringResource` extracts the useless
    /// key `"%@"` instead, which is what this used to do.
    static let noWindowMessage = LocalizedStringResource(
        "Dirnex has no open browser window to act on.",
        comment: "Automation error when Dirnex is running with no browser window to act on."
    )

    /// The same message resolved to plain text, for `NSScriptCommand.scriptErrorString`, which is a
    /// `String` and cannot take the resource itself.
    static var noWindow: String {
        String(localized: noWindowMessage)
    }

    /// The active browser window, via the app delegate — `nil` when no browser window is open.
    @MainActor
    static var activeWindow: BrowserWindowController? {
        (NSApp.delegate as? AppDelegate)?.activeBrowserWindowController
    }
}
