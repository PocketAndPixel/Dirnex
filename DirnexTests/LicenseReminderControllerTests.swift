import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// When the license reminder appears in the app (PLAN.md §M29 Slice 4). The policy itself is pinned
/// in the core; these pin the timing around it: the quiet period, waiting behind another sheet, the
/// record kept in preferences, and the titlebar label.
@Suite("License reminder timing")
@MainActor
struct LicenseReminderControllerTests {
    private static let day: TimeInterval = 24 * 60 * 60
    /// 2027-01-10 07:00 UTC.
    private static let start = Date(timeIntervalSince1970: 1_799_564_400)

    @MainActor
    private struct Rig {
        let controller: LicenseReminderController
        let window: NSWindow
        let clock: TestClock
        let defaults: UserDefaults
        let store: LicenseStore

        var reminder: LicenseReminderSheet? {
            controller.sheet
        }

        func close() {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
    }

    /// A controller over a fresh window. `graceStart` is the recorded start of the quiet period;
    /// `nil` means this is the first launch of a build that reminds.
    private func rig(
        now: Date = start,
        graceStart: Date? = nil,
        key: String? = nil,
        buildReleaseDay: String? = nil,
        isEnabled: Bool = true,
        name: String = "",
        function: String = #function
    ) throws -> Rig {
        let defaults = ScratchDefaults.fresh("records\(name)", function: function)
        defaults.set(graceStart, forKey: AppPreferences.Keys.licenseGraceStart)
        let store = LicenseStore(
            defaults: ScratchDefaults.fresh("store\(name)", function: function),
            buildReleaseDay: buildReleaseDay.flatMap(LicenseDay.init)
        )
        if let key { try store.activate(key).get() }
        let clock = TestClock(now: now)
        let controller = LicenseReminderController(
            isEnabled: isEnabled,
            store: store,
            records: LicenseReminderRecords(defaults: defaults),
            clock: { clock.now },
            realClock: { clock.now }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return Rig(
            controller: controller,
            window: window,
            clock: clock,
            defaults: defaults,
            store: store
        )
    }

    private func start(_ rig: Rig) {
        rig.controller.start { [weak window = rig.window] in window }
    }

    @Test("the first launch starts the quiet period and shows nothing")
    func firstLaunch() async throws {
        let rig = try rig()
        start(rig)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.window.attachedSheet == nil)
        #expect(
            rig.defaults.object(forKey: AppPreferences.Keys.licenseGraceStart) as? Date == Self.start
        )
        #expect(rig.controller.dueVariant == nil)
        rig.close()
    }

    @Test("after thirty days, a launch shows the reminder and records it")
    func afterGrace() async throws {
        let rig = try rig(graceStart: Self.start.addingTimeInterval(-31 * Self.day))
        start(rig)
        try await settleUntil { rig.window.attachedSheet != nil }
        #expect(rig.window.attachedSheet === rig.reminder?.window)
        #expect(rig.reminder?.variant == .buy)
        #expect(rig.controller.dueVariant == .buy)
        #expect(
            rig.defaults.object(forKey: AppPreferences.Keys.licenseReminderLastShown) as? Date == Self.start
        )
        rig.close()
    }

    @Test("a key that ended before this build asks to renew")
    func lapsedKey() async throws {
        let rig = try rig(
            graceStart: Self.start.addingTimeInterval(-31 * Self.day),
            key: TestLicenseKeys.key(until: "2027-03-12"),
            buildReleaseDay: "2027-04-01"
        )
        start(rig)
        try await settleUntil { rig.window.attachedSheet != nil }
        #expect(rig.reminder?.variant == .renew(until: try #require(LicenseDay("2027-03-12"))))
        rig.close()
    }

    @Test("a key that covers this build silences it, and so does a build that doesn't remind")
    func silenced() async throws {
        let covered = try rig(
            graceStart: Self.start.addingTimeInterval(-40 * Self.day),
            key: TestLicenseKeys.key(until: "2027-03-12"),
            buildReleaseDay: "2027-03-12",
            name: "covered"
        )
        let disabled = try rig(
            graceStart: Self.start.addingTimeInterval(-40 * Self.day),
            isEnabled: false,
            name: "disabled"
        )
        start(covered)
        start(disabled)
        try await Task.sleep(for: .milliseconds(300))
        #expect(covered.window.attachedSheet == nil)
        #expect(disabled.window.attachedSheet == nil)
        #expect(covered.controller.dueVariant == nil)
        #expect(disabled.controller.dueVariant == nil)
        #expect(
            disabled.defaults.object(forKey: AppPreferences.Keys.licenseGraceStart) as? Date != Self.start
        )
        covered.close()
        disabled.close()
    }

    @Test("it waits behind another sheet, and appears once that one closes")
    func waitsBehindSheet() async throws {
        let rig = try rig(graceStart: Self.start.addingTimeInterval(-31 * Self.day))
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        other.isReleasedWhenClosed = false
        rig.window.beginSheet(other) { _ in }
        try await settleUntil { rig.window.attachedSheet === other }
        start(rig)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(rig.window.attachedSheet === other)
        #expect(rig.defaults.object(forKey: AppPreferences.Keys.licenseReminderLastShown) == nil)

        rig.window.endSheet(other)
        try await settleUntil { rig.reminder != nil && rig.window.attachedSheet === rig.reminder?.window }
        rig.close()
    }

    @Test("once a day: not again on the same day's activation, but again the next day")
    func oncePerDay() async throws {
        let rig = try rig(graceStart: Self.start.addingTimeInterval(-31 * Self.day))
        start(rig)
        try await settleUntil { rig.reminder != nil }
        rig.reminder?.okButton.performClick(nil)
        try await settleUntil { rig.window.attachedSheet == nil && rig.reminder == nil }

        rig.clock.now = Self.start.addingTimeInterval(3600)
        rig.controller.handle(.activation)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.window.attachedSheet == nil)

        rig.clock.now = Self.start.addingTimeInterval(Self.day)
        rig.controller.handle(.activation)
        try await settleUntil { rig.window.attachedSheet != nil }
        rig.close()
    }

    @Test("the titlebar label shows while the reminder is due, and says which")
    func titlebarLabel() async throws {
        let quiet = try rig(name: "quiet")
        start(quiet)
        let quietLabel = LicenseTitlebarLabel(reminders: quiet.controller)
        #expect(!quietLabel.isShowing)
        #expect(quietLabel.button.isHidden)

        let due = try rig(graceStart: Self.start.addingTimeInterval(-31 * Self.day), name: "due")
        start(due)
        let dueLabel = LicenseTitlebarLabel(reminders: due.controller)
        #expect(dueLabel.isShowing)
        #expect(dueLabel.button.title == LicenseTitlebarLabel.title(for: .buy))

        // A key entered while the label shows takes it away at once.
        try due.store.activate(TestLicenseKeys.key())
        try await settleUntil { !dueLabel.isShowing }
        #expect(dueLabel.button.isHidden)
        quiet.close()
        due.close()
    }
}

final class TestClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
