import Foundation
import Testing

@testable import DirnexCore

@Suite("UpdateAvailability")
struct UpdateAvailabilityTests {
    @Test("nothing is pending at launch")
    func noneIsEmpty() {
        #expect(UpdateAvailability.none.isAvailable == false)
        #expect(UpdateAvailability.none.pendingVersion == nil)
    }

    @Test("a found update carries its version")
    func availableKeepsVersion() {
        let state = UpdateAvailability.available(version: "1.3.0")
        #expect(state.isAvailable)
        #expect(state.pendingVersion == "1.3.0")
    }

    @Test("a blank version still raises the indicator, just without a version to show")
    func blankVersionStillAvailable() {
        for version in [nil, "", "   ", "\n"] as [String?] {
            let state = UpdateAvailability.available(version: version)
            #expect(state.isAvailable)
            #expect(state.pendingVersion == nil)
        }
    }

    @Test("surrounding whitespace is trimmed off the version")
    func versionIsTrimmed() {
        #expect(UpdateAvailability.available(version: " 1.3.0 ").pendingVersion == "1.3.0")
    }

    @Test("dismissing Sparkle's dialog keeps the indicator up — that is the whole point of it")
    func dismissKeepsIndicator() {
        let state = UpdateAvailability.available(version: "1.3.0")
        #expect(state.afterUserChoice(.dismiss) == state)
    }

    @Test("skipping a version clears the indicator, since Sparkle won't raise it again")
    func skipClearsIndicator() {
        let state = UpdateAvailability.available(version: "1.3.0")
        #expect(state.afterUserChoice(.skip) == .none)
    }

    @Test("installing clears the indicator — the app is relaunching into that version")
    func installClearsIndicator() {
        let state = UpdateAvailability.available(version: "1.3.0")
        #expect(state.afterUserChoice(.install) == .none)
    }

    @Test("no choice can conjure an indicator out of an empty state")
    func choicesFromNoneStayEmpty() {
        for choice in UpdateChoice.allCases {
            #expect(UpdateAvailability.none.afterUserChoice(choice) == .none)
        }
    }

    // The tooltip's *wording* moved to the app in M12 Slice 11 (it has to be translated, and the
    // core ships no resources), so its tests moved with it — `UpdateIndicatorTooltipTests`. What
    // drives it is the state above, which is covered here and is the part that can be wrong.
}
