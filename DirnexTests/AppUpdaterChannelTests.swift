import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app-side half of the beta/stable update channels (PLAN.md §M7). The channel policy itself
/// (opt-in → allowed set) is pinned in `DirnexCore.UpdateChannels`; what these guard is the wiring
/// that can't be seen from the core:
///
/// - that Swift actually mapped `allowedChannels(for:)` onto Sparkle's Objective-C
///   `allowedChannelsForUpdater:` selector, so the delegate hook is really reachable and not a
///   method that compiles but is never called; and
/// - that the off-main reader Sparkle uses sees the same persisted value the Settings toggle writes.
@MainActor
@Suite("AppUpdater beta channel")
struct AppUpdaterChannelTests {
    @Test(
        "the updater answers Sparkle's allowedChannels selector, so the opt-in isn't a silent no-op"
    )
    func respondsToAllowedChannelsSelector() {
        // Sparkle dispatches its optional delegate methods through the Objective-C runtime as
        // `allowedChannelsForUpdater:`. `#selector` here only compiles because Swift exposed the
        // witness under that exact selector (a signature mismatch would drop the @objc and fail to
        // build), and `responds(to:)` confirms it's live in the method table. `AppUpdater()` is
        // inert under tests (no updater started), but its class still carries the witness.
        let updater = AppUpdater()
        #expect(updater.responds(to: #selector(AppUpdater.allowedChannels(for:))))
    }

    @Test("the off-main reader round-trips the persisted beta opt-in that Sparkle consults")
    func readerReflectsPersistedPreference() throws {
        let suiteName = "AppUpdaterChannelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Default off — a fresh install rides the stable channel.
        #expect(AppPreferences.receiveBetaUpdatesValue(in: defaults) == false)
        #expect(UpdateChannels.allowed(
            receiveBetaUpdates: AppPreferences.receiveBetaUpdatesValue(in: defaults)
        ).isEmpty)

        // Flipping the Settings toggle persists, and the reader picks it up on the next check.
        let preferences = AppPreferences(defaults: defaults)
        preferences.receiveBetaUpdates = true
        #expect(AppPreferences.receiveBetaUpdatesValue(in: defaults) == true)
        #expect(UpdateChannels.allowed(
            receiveBetaUpdates: AppPreferences.receiveBetaUpdatesValue(in: defaults)
        ) == ["beta"])
    }
}
