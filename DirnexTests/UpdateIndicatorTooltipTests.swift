import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The titlebar update indicator's tooltip (PLAN.md §M7, §M12 Slice 11).
///
/// The wording lives in the app rather than on `DirnexCore.UpdateAvailability`: the core owns the
/// *state* and ships no resources, so a sentence composed there could never be translated — and this
/// control is on screen permanently. These tests came over from `UpdateAvailabilityTests` with the
/// words; the state machine they read is still pinned in the core.
///
/// They assert against the localized primitives rather than English literals, so the suite passes
/// whatever language the app test target inherits (docs/NOTES.md).
@MainActor
@Suite("Update indicator tooltip")
struct UpdateIndicatorTooltipTests {
    @Test("the tooltip names the version when the appcast gave one")
    func namesVersion() {
        let tooltip = BrowserWindowController.tooltip(for: .available(version: "1.3.0"))
        #expect(tooltip == String(localized: "Dirnex \("1.3.0") is available — click to install"))
        // The version is the one thing the glyph cannot say, so it must survive whatever the
        // translation does to the sentence around it.
        #expect(tooltip.contains("1.3.0"))
    }

    @Test("a version-less update still gets a tooltip, not a blank one")
    func fallsBackWithoutVersion() {
        // `available(version:)` normalises a blank version to `nil` (pinned in the core), and the
        // indicator still has to say *something* — "Dirnex  is available" is the failure this
        // branch exists to avoid.
        for version in [nil, "", "   "] as [String?] {
            let tooltip = BrowserWindowController.tooltip(for: .available(version: version))
            #expect(tooltip == String(localized: "An update is available — click to install"))
        }
    }

    @Test("with nothing pending the tooltip describes the check the button would run")
    func idleDescribesTheCheck() {
        #expect(
            BrowserWindowController.tooltip(for: .none) == String(localized: "Check for updates")
        )
    }

    @Test("every state yields a non-empty tooltip in the current language")
    func neverEmpty() {
        for availability in [.none, .available(version: nil), .available(version: "1.3.0")]
            as [UpdateAvailability] {
            #expect(!BrowserWindowController.tooltip(for: availability).isEmpty)
        }
    }
}
