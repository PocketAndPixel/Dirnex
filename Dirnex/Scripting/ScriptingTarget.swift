import AppKit

/// The window an automation surface acts on (PLAN.md §M6 "Automation: AppleScript/Shortcuts verbs").
///
/// Shared by both doors into the app — the `NSScriptCommand` handlers in `ScriptingCommands.swift`
/// and the App Intents in `AutomationIntents.swift` — so "which window does a scripted verb hit"
/// has exactly one answer. The AppleScript-specific error numbers stay with the handlers; only the
/// target lookup is common ground.
enum Scripting {
    /// Shown when automation arrives with no window to act on — the app can be running with every
    /// browser window closed, and both surfaces report that the same way.
    static let noWindowMessage = "Dirnex has no open browser window to act on."

    /// The active browser window, via the app delegate — `nil` when no browser window is open.
    @MainActor
    static var activeWindow: BrowserWindowController? {
        (NSApp.delegate as? AppDelegate)?.activeBrowserWindowController
    }
}
