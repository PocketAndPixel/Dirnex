import AppKit
import DirnexCore

// The AppleScript verb handlers (PLAN.md §M6 "Automation: AppleScript/Shortcuts verbs"). Each
// `NSScriptCommand` subclass is named in `Dirnex.sdef` via <cocoa class="…">, and the `@objc(…)`
// names below are exactly those strings. AppKit delivers Apple events on the main thread and calls
// `performDefaultImplementation()`, so each handler decodes its direct parameter, asserts the main
// isolation it already has, and hands the work to the active browser window
// (`BrowserWindowController+Scripting.swift`). The pure decisions — is this a valid path, which
// command does this name mean — live in `DirnexCore.Automation`, tested there.
//
// A handler returns a Bool result (the sdef declares it) and, on failure, sets `scriptErrorNumber`
// / `scriptErrorString` so a script sees a real AppleScript error rather than a silent no-op.

/// `reveal "<posix path>"` — bring the active panel to the item and select it.
@objc(DirnexRevealScriptCommand)
final class DirnexRevealScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let path = directParameter as? String else {
            return fail(
                AppleScriptError.missingParameter,
                "reveal needs a POSIX path, e.g. reveal \"/Users/me\"."
            )
        }
        guard let target = AutomationReveal.target(forPOSIXPath: path) else {
            return fail(AppleScriptError.notFound, "\"\(path)\" is not an absolute POSIX path.")
        }
        // Only the window work needs the main actor; its result comes back as a Sendable Bool
        // (assumeIsolated requires that) so the Any?/error is built out here. `false` = no window.
        let revealed = MainActor.assumeIsolated { () -> Bool in
            guard let window = Scripting.activeWindow else { return false }
            window.reveal(target)
            return true
        }
        return revealed ? true : fail(AppleScriptError.notFound, Scripting.noWindowMessage)
    }
}

/// `copy selection` — copy the active panel's selection to the other panel (the F5 op).
@objc(DirnexCopySelectionScriptCommand)
final class DirnexCopySelectionScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // `nil` = no window; otherwise the dispatch result (file.copy always resolves, so `true`).
        let ran = MainActor.assumeIsolated { () -> Bool? in
            guard let window = Scripting.activeWindow else { return nil }
            return window.runCommand(id: "file.copy")
        }
        guard let ran else { return fail(AppleScriptError.notFound, Scripting.noWindowMessage) }
        return ran
    }
}

/// `run operation "<id or title>"` — dispatch any Dirnex command, or a user script, by name.
@objc(DirnexRunOperationScriptCommand)
final class DirnexRunOperationScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let query = directParameter as? String else {
            return fail(
                AppleScriptError.missingParameter,
                "run operation needs a command id or title."
            )
        }
        // Resolution is pure (and the store read is nonisolated), so only the dispatch is isolated.
        let scripts = UserScriptStore.load().scripts
        guard let id = AutomationOperation.resolve(query, userScripts: scripts) else {
            return fail(AppleScriptError.notFound, "\"\(query)\" is not a known Dirnex operation.")
        }
        let ran = MainActor.assumeIsolated { () -> Bool? in
            guard let window = Scripting.activeWindow else { return nil }
            return window.runCommand(id: id)
        }
        guard let ran else { return fail(AppleScriptError.notFound, Scripting.noWindowMessage) }
        return ran ? true : fail(AppleScriptError.notFound, "\"\(query)\" could not be run.")
    }
}

// MARK: - Shared

/// The AppleScript error numbers the three handlers report with, kept in one place so they fail
/// consistently. The window they act on is `Scripting.activeWindow`, shared with the App Intents
/// surface (see `ScriptingTarget.swift`).
private enum AppleScriptError {
    /// Standard AppleScript/Apple-event error numbers (from `<CarbonCore/MacErrors.h>`), spelled
    /// out as literals so the file needn't import Carbon: `errAEParamMissed` for an absent/mistyped
    /// direct parameter, and `errAENoSuchObject` for a path, operation, or window we can't resolve.
    static let missingParameter = -1715
    static let notFound = -1728
}

private extension NSScriptCommand {
    /// Record an AppleScript error on this command and return a `false` result, so a script both
    /// sees the boolean fail and gets a readable `error` message.
    func fail(_ code: Int, _ message: String) -> Any? {
        scriptErrorNumber = code
        scriptErrorString = message
        return false
    }
}
