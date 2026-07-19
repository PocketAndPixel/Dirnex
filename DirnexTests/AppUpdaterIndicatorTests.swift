import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app-side half of the titlebar update indicator (PLAN.md §M7). The state machine itself
/// (found → available, dismiss keeps, skip/install clear) is pinned in
/// `DirnexCore.UpdateAvailability`; what these guard is the wiring the core can't see:
///
/// - that Swift really mapped each callback onto the Objective-C selector Sparkle dispatches, so a
///   background find is not a hook that compiles but is never called; and
/// - that an install starts with no badge, so the indicator can only ever come from a real check.
@MainActor
@Suite("AppUpdater update indicator")
struct AppUpdaterIndicatorTests {
    /// Sparkle sends its optional delegate messages through the Objective-C runtime, by selector. A
    /// Swift signature that drifts from the imported one still compiles — it just silently stops
    /// being the witness — so these check the method table by name, the way Sparkle will.
    @Test("the updater answers every Sparkle callback the indicator is driven by")
    func respondsToAvailabilitySelectors() {
        let updater = AppUpdater()
        for selector in [
            "updater:didFindValidUpdate:",
            "updaterDidNotFindUpdate:",
            "updater:userDidMakeChoice:forUpdate:state:"
        ] {
            #expect(
                updater.responds(to: NSSelectorFromString(selector)),
                "Sparkle dispatches \(selector); the delegate must carry it"
            )
        }
    }

    @Test("a fresh updater shows no update, so the badge can only come from a real check")
    func startsWithNothingPending() {
        // Inert under tests (no Sparkle updater is started), which is exactly the state the badge
        // must read as "nothing to show".
        #expect(AppUpdater().availability == .none)
        #expect(AppUpdater().availability.isAvailable == false)
    }
}
