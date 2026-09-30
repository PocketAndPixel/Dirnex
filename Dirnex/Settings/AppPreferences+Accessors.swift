import DirnexCore
import Foundation

/// The entry points the rest of the app calls on ``AppPreferences``, as against the values the
/// Settings window binds to.
///
/// Split out when the class reached SwiftLint's file ceiling, and split here rather than anywhere
/// cheaper because this is the seam that already existed: everything below is *derived* — a toggle
/// several surfaces share so they cannot drift, a unit conversion the Settings field edits in, or a
/// read taken from somewhere the main actor is not. Nothing here is stored, and nothing here is a
/// preference of its own; the values, their `UserDefaults` writes and their change notifications
/// stay together in `AppPreferences.swift`, where the argument for each default is written down.
extension AppPreferences {
    /// Flip the app-wide show-hidden state. The shared entry point for the header button, the
    /// ⇧⌘. shortcut, and the palette/menu command — all of which want the same one-line effect.
    /// The View menu owns this toggle; Settings deliberately does not restate it.
    func toggleShowHidden() {
        showHidden.toggle()
    }

    /// Flip the app-wide tags-column state — the shared entry point for the View menu item and the
    /// palette command, which own this toggle; Settings deliberately does not restate it.
    func toggleShowTags() {
        showTags.toggle()
    }

    /// Flip the app-wide sync-badge state — the shared entry point for the View menu item and the
    /// palette command, which own this toggle; Settings deliberately does not restate it.
    func toggleShowSyncStatus() {
        showSyncStatus.toggle()
    }

    /// Flip the app-wide function-bar state — the shared entry point for the View menu item and the
    /// palette command, which own this toggle; Settings deliberately does not restate it.
    func toggleShowFunctionBar() {
        showFunctionBar.toggle()
    }

    /// The same floor as the whole number of seconds the Settings field edits. A computed forward
    /// rather than a second stored value, so the two can never disagree about what is in force.
    var remoteRefreshFloorSeconds: Int {
        get { Int(remoteRefreshFloor.rounded()) }
        set { remoteRefreshFloor = TimeInterval(newValue) }
    }

    /// The same limit in the decimal megabytes the Settings field edits. A computed forward rather
    /// than a second stored value, so the two can never disagree about what is in force.
    var quickViewFetchLimitMegabytes: Int {
        get { Int(quickViewFetchLimit / 1_000_000) }
        set { quickViewFetchLimit = Int64(newValue) * 1_000_000 }
    }

    /// A read of the same value for the one caller that needs it *per navigation* rather than per
    /// change: `QuickViewWebView`'s policy delegate, which is handed a fresh `WKWebpagePreferences`
    /// for every load and sets it there. Reading it at each navigation is what makes the toggle
    /// take effect on a live web view — the value baked into a `WKWebViewConfiguration` at init
    /// cannot be changed afterwards (probed: mutating `webView.configuration` is inert, and reads
    /// back as though it worked).
    static var quickViewJavaScriptValue: Bool {
        shared.quickViewJavaScriptEnabled
    }

    /// A thread-safe read of the beta-updates opt-in straight from `UserDefaults`, for the one
    /// caller that runs off the main actor: Sparkle's `allowedChannels(for:)` delegate hook, which
    /// it invokes synchronously inside an update check. `UserDefaults` is itself thread-safe, so
    /// this reads the same key the `@MainActor` `receiveBetaUpdates` property writes without hopping
    /// actors, and re-reads every call so a Settings toggle is picked up on the next check.
    nonisolated static func receiveBetaUpdatesValue(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Keys.receiveBetaUpdates)
    }
}
