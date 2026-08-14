import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The one number in `RemoteFetchPolicy`'s table the user owns: how large a file Quick View may pull
/// down from a server on its own (Settings ▸ Panels, PLAN.md §M21 Slice 10).
///
/// The policy itself is pinned in the core. What these hold is the *storage*, which is where this
/// setting can go wrong in ways no policy test can see — a missing key that reads as a real value, a
/// hand-edited domain, and the megabyte view disagreeing with the bytes it forwards to.
@MainActor
@Suite("Quick View fetch limit preference")
struct QuickViewFetchLimitPreferenceTests {
    /// A defaults domain of its own per test, so nothing here reads or writes the settings of
    /// whoever is running the suite — the app test target runs *inside* the app (docs/NOTES.md).
    private func isolatedDefaults() -> UserDefaults {
        let suite = "Dirnex.tests.fetchLimit.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    /// The trap this setting is built around: `UserDefaults.integer(forKey:)` answers **0** for a key
    /// that was never written, and 0 is a legitimate value here — "never fetch unasked". The cheap
    /// spelling would therefore hand every fresh install the one setting that turns the feature off,
    /// and it would read as the feature never having worked rather than as a default.
    @Test("a fresh install gets the default limit, not the zero a missing key reads as")
    func freshInstallGetsTheDefault() {
        let preferences = AppPreferences(defaults: isolatedDefaults())

        #expect(preferences.quickViewFetchLimit == RemoteFetchPolicy.defaultPreviewLimit)
        #expect(preferences.quickViewFetchLimit > 0)
    }

    @Test("a stored limit is restored")
    func storedLimitIsRestored() {
        let defaults = isolatedDefaults()
        AppPreferences(defaults: defaults).quickViewFetchLimit = 300 * 1_000_000

        #expect(AppPreferences(defaults: defaults).quickViewFetchLimit == 300 * 1_000_000)
    }

    /// Zero has to survive the round trip *as zero*, which is the same assertion as the one above
    /// read from the other side: if "never" were indistinguishable from "unset", the setting would
    /// silently revert to the default on the next launch.
    @Test("zero is stored and restored as zero, not as the default")
    func zeroSurvivesRestart() {
        let defaults = isolatedDefaults()
        AppPreferences(defaults: defaults).quickViewFetchLimit = 0

        #expect(AppPreferences(defaults: defaults).quickViewFetchLimit == 0)
    }

    /// A defaults domain is hand-editable by design (PLAN.md §2), so a value from outside the band
    /// has to be brought inside rather than honoured — in both directions, and on the way *in* as
    /// well as on the way out.
    @Test("a limit outside the band is clamped, however it arrives")
    func outOfBandValuesAreClamped() {
        let range = RemoteFetchPolicy.previewLimitRange
        let defaults = isolatedDefaults()
        defaults.set(range.upperBound * 10, forKey: "Dirnex.pref.quickViewFetchLimit")

        #expect(AppPreferences(defaults: defaults).quickViewFetchLimit == range.upperBound)

        let preferences = AppPreferences(defaults: isolatedDefaults())
        preferences.quickViewFetchLimit = -5
        #expect(preferences.quickViewFetchLimit == range.lowerBound)
    }

    /// The megabyte view is what Settings edits and the bytes are what the policy reads, so the two
    /// disagreeing would put a number on screen that is not the one in force.
    @Test("the megabyte view and the stored bytes are the same setting")
    func megabytesForwardToBytes() {
        let preferences = AppPreferences(defaults: isolatedDefaults())

        preferences.quickViewFetchLimitMegabytes = 300
        #expect(preferences.quickViewFetchLimit == 300 * 1_000_000)

        preferences.quickViewFetchLimit = 25 * 1_000_000
        #expect(preferences.quickViewFetchLimitMegabytes == 25)
    }

    /// The setting has to reach an *open* preview, or raising it resolves the card after the next
    /// cursor step rather than the one the user is looking at while they change it.
    @Test("changing the limit posts the notification an open preview listens for")
    func changingTheLimitPostsItsNotification() async {
        let preferences = AppPreferences(defaults: isolatedDefaults())
        // The shared counter from `RemoteFetchFixtures` — a plain `var` captured by an
        // escaping closure cannot be mutated from it; a tiny reference type can.
        let heard = Landing()
        let token = NotificationCenter.default.addObserver(
            forName: AppPreferences.quickViewFetchLimitDidChange,
            object: preferences,
            queue: .main
        ) { _ in MainActor.assumeIsolated { heard.times += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.quickViewFetchLimit = 300 * 1_000_000
        // Setting it to what it already is must stay silent, or every Settings redraw would
        // re-deliver every open preview.
        preferences.quickViewFetchLimit = 300 * 1_000_000
        for _ in 0..<20 where heard.times == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(heard.times == 1)
    }

    /// The default has to be a value the Settings field can actually show and the stepper can reach;
    /// a default outside the band would be silently rewritten the first time anybody opened the tab.
    @Test("the default is a whole number of megabytes inside the offered band")
    func defaultIsExpressibleInTheField() {
        let preferences = AppPreferences(defaults: isolatedDefaults())
        let megabytes = preferences.quickViewFetchLimitMegabytes

        #expect(Int64(megabytes) * 1_000_000 == RemoteFetchPolicy.defaultPreviewLimit)
        #expect(RemoteFetchPolicy.previewLimitRange.contains(preferences.quickViewFetchLimit))
    }
}
