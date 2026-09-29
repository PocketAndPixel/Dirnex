import AppKit
import DirnexCore
import Foundation
import Sparkle
import Testing

@testable import Dirnex

/// Updates the license doesn't cover (PLAN.md §M29 Slice 5). The rule is `UpdateCoverageGate`'s and
/// tested in the core; these pin the wiring: that Sparkle reaches the hook at all, that it throws
/// the one error Sparkle ends a check on silently, and that a background check can't get past it.
@Suite("AppUpdater: updates the license doesn't cover")
@MainActor
struct AppUpdaterCoverageTests {
    /// The running build came out on 2027-02-01, and the key covers releases until 2027-03-12.
    private func updater(
        until: String? = "2027-03-12",
        licensingIsOn: Bool = true
    ) throws -> AppUpdater {
        let store = LicenseStore(
            defaults: ScratchDefaults.fresh(),
            verifiers: [.test],
            buildReleaseDay: LicenseDay("2027-02-01")
        )
        if let until {
            _ = try store.activate(TestLicenseKeys.key(until: until)).get()
        }
        return AppUpdater(licenseStore: store, licensingIsOn: licensingIsOn)
    }

    /// Noon UTC on `day`.
    private static func date(_ day: String) throws -> Date {
        try #require(LicenseDay(day)).date(in: .gmt)
    }

    /// The notice for 1.4.0, released 2027-04-01, under the key above.
    private static var notice: UpdateCoverageNotice {
        get throws {
            let key = try LicenseVerifier.test.check(TestLicenseKeys.key(until: "2027-03-12")).get()
            return try #require(UpdateCoverageNotice.notice(
                key: key,
                currentReleaseDay: LicenseDay("2027-02-01"),
                updateVersion: "1.4.0",
                updateReleaseDay: LicenseDay("2027-04-01")
            ))
        }
    }

    private func check(
        _ updater: AppUpdater,
        released day: String = "2027-04-01",
        build: String = "50",
        _ check: SPUUpdateCheck
    ) throws {
        try updater.gate(version: "1.4.0", build: build, releaseDate: Self.date(day), check: check)
    }

    /// Whether `body` threw exactly the error Sparkle ends a check on without a word.
    private func isHeldBack(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch {
            let error = error as NSError
            return error.domain == SUSparkleErrorDomain
                && error.code == Int(SUError.installationCanceledError.rawValue)
        }
    }

    @Test("the updater answers Sparkle's hook and end-of-check selectors")
    func respondsToSelectors() throws {
        // By selector string: `#selector` resolves against the protocol and would keep naming the
        // right selector after the class stopped implementing it (docs/NOTES.md ▸ Testing).
        let updater = try updater()
        for name in [
            "updater:shouldProceedWithUpdate:updateCheck:error:",
            "updater:didFinishUpdateCycleForUpdateCheck:error:"
        ] {
            #expect(updater.responds(to: NSSelectorFromString(name)), "\(name)")
        }
    }

    @Test("a background check can't get past the hook with an update the license doesn't cover")
    func backgroundIsHeldBack() throws {
        let updater = try updater()
        #expect(isHeldBack { try check(updater, .updatesInBackground) })
        #expect(updater.pendingCoverageNotice == nil)
    }

    @Test("a user-initiated check is held back, and leaves the notice to show once it has ended")
    func userInitiatedLeavesNotice() throws {
        let updater = try updater()
        #expect(isHeldBack { try check(updater, .updates) })
        #expect(
            try updater.pendingCoverageNotice == PendingCoverageNotice(
                notice: Self.notice,
                build: "50"
            )
        )
    }

    @Test("the probe goes on, so the titlebar indicator still lights")
    func probeGoesOn() throws {
        let updater = try updater()
        try check(updater, .updateInformation)
        #expect(updater.pendingCoverageNotice == nil)
    }

    @Test("nothing is held back when the update is covered, with no key, or in a dormant build")
    func nothingHeldBackOtherwise() throws {
        let checks: [SPUUpdateCheck] = [.updates, .updatesInBackground, .updateInformation]
        let covered = try updater()
        let keyless = try updater(until: nil)
        let dormant = try updater(licensingIsOn: false)
        for kind in checks {
            // The key's last day is covered, late in the day or not.
            try check(covered, released: "2027-03-12", kind)
            try check(keyless, kind)
            try check(dormant, kind)
        }
        #expect(covered.pendingCoverageNotice == nil)
        #expect(keyless.pendingCoverageNotice == nil)
        #expect(dormant.pendingCoverageNotice == nil)
    }

    @Test("Update Anyway lets that build through every check, and Not Now doesn't")
    func choices() throws {
        let updater = try updater()
        let pending = try PendingCoverageNotice(notice: Self.notice, build: "50")
        updater.handle(.notNow, for: pending)
        #expect(isHeldBack { try check(updater, .updatesInBackground) })

        updater.handle(.updateAnyway, for: pending)
        try check(updater, .updatesInBackground)
        try check(updater, .updates)
        #expect(updater.pendingCoverageNotice == nil)
        // A release that came out meanwhile is a new question.
        #expect(isHeldBack { try check(updater, build: "51", .updates) })
    }

    @Test("the release day is the UTC day, whatever the Mac's time zone")
    func releaseDayIsUTC() throws {
        let updater = try updater()
        // Late on the key's last day in UTC is covered; ten minutes after midnight UTC isn't. In
        // Kyiv the first is already the next day, and in California the second is still the last.
        let lastMinute = try Self.date("2027-03-12").addingTimeInterval(11 * 3600 + 30 * 60)
        try updater.gate(
            version: "1.4.0", build: "50", releaseDate: lastMinute, check: .updatesInBackground
        )
        let justAfter = try Self.date("2027-03-13").addingTimeInterval(-(11 * 3600 + 50 * 60))
        #expect(isHeldBack {
            try updater.gate(
                version: "1.4.0", build: "50", releaseDate: justAfter, check: .updatesInBackground
            )
        })
        // An undated update counts as covered, like an undated build.
        try updater.gate(version: "1.4.0", build: "50", releaseDate: nil, check: .updates)
        #expect(updater.pendingCoverageNotice == nil)
    }

    // MARK: - The notice

    @Test("the notice names the version and the end day; Not Now takes Return and Escape")
    func noticeAlert() throws {
        let notice = try Self.notice
        let alert = UpdateCoverageAlert.alert(for: notice)
        #expect(alert.messageText.contains("1.4.0"))
        #expect(alert.informativeText.contains(notice.until.displayText))
        #expect(alert.informativeText.contains("1.4.0"))
        #expect(alert.buttons.count == 3)
        #expect(alert.buttons.map(\.keyEquivalent) == ["\r", "", ""])
        // Space presses the focused button, so the focus starts on Not Now too.
        #expect(alert.window.initialFirstResponder === alert.buttons.first)
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        let catcher = alert.window.contentView?.subviews.compactMap { $0 as? AlertKeyCatcher }.first
        #expect(catcher?.button(for: escape) === alert.buttons.first)
    }

    @Test("each button reports its choice")
    func noticeChoices() {
        #expect(UpdateCoverageAlert.choice(for: .alertFirstButtonReturn) == .notNow)
        #expect(UpdateCoverageAlert.choice(for: .alertSecondButtonReturn) == .updateAnyway)
        #expect(UpdateCoverageAlert.choice(for: .alertThirdButtonReturn) == .renew)
        #expect(UpdateCoverageAlert.choice(for: .abort) == .notNow)
    }
}
