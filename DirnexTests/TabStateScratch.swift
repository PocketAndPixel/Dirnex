import Foundation

/// The defaults domain a test hands a pane that has a `restorationKey`, so the tabs it persists
/// never reach the developer's own `com.dirnex.Dirnex`.
///
/// The app test target runs inside the app, so `UserDefaults.standard` is the real domain
/// (docs/NOTES.md ▸ Testing), and removing a key when the test ends is not enough: a pane that
/// navigates calls `persistState()` again when the listing lands, which can be after the test has
/// returned. Before this, `RemoteTabPersistenceTests` left two `Dirnex.tabs.reconnect-test-<UUID>`
/// keys behind on every run, and 930 had built up by 2026-09-13.
///
/// One fixed domain, not one per test: `removePersistentDomain(forName:)` empties a domain but
/// leaves its plist in `~/Library/Preferences`, so a UUID-named suite leaks a file per test instead
/// of a key. Tests keep their own UUID keys inside it, and it is cleared once per test host, the
/// first time anything asks for it, which also takes whatever the previous run's late writes left.
@MainActor
enum TabStateScratch {
    static let suiteName = "com.dirnex.tests.tabs"

    static let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }()
}
