import AppKit
import DirnexCore

/// Puts the license reminder in front of the user when `LicenseReminderPolicy` says so (PLAN.md §M29
/// "When it appears"): at every launch, and once a day at the first activation from 13:00, once the
/// thirty quiet days are over and no key covers this build.
///
/// The policy is the core's and tested there; this is the timing. Two rules live here:
///
/// - **It never stacks over another sheet or a modal dialog.** The first-run tour and the Full Disk
///   Access prompt only ever appear on the first launch of any Dirnex, when the quiet period has just
///   begun, so at launch they can't meet. The daily activation can land while any sheet is up (a
///   copy conflict left open since the morning), so the reminder waits until the window is clear.
/// - **It counts as shown only once it's on screen.** A reminder that waited is recorded when it
///   appears, not when it was due.
@MainActor
final class LicenseReminderController {
    static let shared = LicenseReminderController()

    /// Posted when whether the reminder is due may have changed, for the titlebar label.
    static let dueDidChange = Notification.Name("Dirnex.licenseReminderDueDidChange")

    let isEnabled: Bool
    private let store: LicenseStore
    private let policy: LicenseReminderPolicy
    private let records: LicenseReminderRecords
    private let clock: () -> Date
    private let realClock: () -> Date
    private var record: LicenseReminderRecord
    private var window: () -> NSWindow? = { nil }
    private var isStarted = false
    /// Waiting for a clear window, or on screen.
    private var isPresenting = false
    private(set) var sheet: LicenseReminderSheet?

    init(
        isEnabled: Bool = LicensingSwitch.reminds,
        store: LicenseStore = .shared,
        policy: LicenseReminderPolicy = LicenseReminderPolicy(),
        records: LicenseReminderRecords = .forThisBuild,
        clock: @escaping () -> Date = LicenseReminderController.buildClock,
        realClock: @escaping () -> Date = Date.init
    ) {
        self.isEnabled = isEnabled
        self.store = store
        self.policy = policy
        self.records = records
        self.clock = clock
        self.realClock = realClock
        record = records.load()
    }

    /// The clock the reminder runs on: now, or now plus `-DirnexDebugLicenseDaysAhead` days.
    nonisolated static func buildClock() -> Date {
        Date().addingTimeInterval(TimeInterval(LicensingSwitch.debugDaysAhead ?? 0) * 24 * 60 * 60)
    }

    /// Which reminder is due right now, or `nil`. The titlebar label shows exactly while this isn't
    /// `nil`.
    var dueVariant: LicenseReminderVariant? {
        guard isEnabled, policy.isDue(store.status, record: record, now: clock()) else { return nil }
        return store.status.reminderVariant
    }

    /// Call once the browser window is on screen. Starts the quiet period on the first launch of a
    /// build with the switch on, then treats this as the launch.
    func start(window: @escaping () -> NSWindow?) {
        guard isEnabled, !isStarted else { return }
        isStarted = true
        self.window = window
        // Armed on the real clock, so a Debug run with the clock moved ahead starts its quiet period
        // now and finds it over.
        record = policy.armed(record, now: realClock())
        records.save(record)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(licenseDidChange),
            name: LicenseStore.didChange,
            object: store
        )
        handle(.launch)
    }

    @objc private func applicationDidBecomeActive() {
        handle(.activation)
    }

    @objc private func licenseDidChange() {
        NotificationCenter.default.post(name: Self.dueDidChange, object: self)
    }

    /// Show the reminder if `trigger` calls for it. Internal for the tests.
    func handle(_ trigger: LicenseReminderPolicy.Trigger) {
        NotificationCenter.default.post(name: Self.dueDidChange, object: self)
        guard !isPresenting,
              policy.shouldShow(trigger, status: store.status, record: record, now: clock())
        else {
            return
        }
        isPresenting = true
        Task { await presentWhenClear() }
    }

    /// Wait until the window has no sheet and no modal dialog is up, then show the reminder, unless
    /// it stopped being due meanwhile (a key entered in the dialog it waited behind).
    private func presentWhenClear() async {
        while let window = window(), window.attachedSheet != nil || NSApp.modalWindow != nil {
            try? await Task.sleep(for: .seconds(1))
        }
        guard let window = window(), let variant = dueVariant else {
            isPresenting = false
            return
        }
        let sheet = LicenseReminderSheet(variant: variant)
        sheet.onChoice = { [weak self] choice in self?.chose(choice) }
        self.sheet = sheet
        sheet.present(over: window)
        record = policy.recordingShown(record, now: clock())
        records.save(record)
    }

    private func chose(_ choice: LicenseReminderSheet.Choice) {
        sheet = nil
        isPresenting = false
        switch choice {
        case .ok:
            break
        case .buy:
            if case .renew = store.status.reminderVariant, let key = store.key {
                NSWorkspace.shared.open(LicenseLinks.renew(key))
            } else {
                NSWorkspace.shared.open(LicenseLinks.buy)
            }
        case .enterLicense:
            SettingsWindowController.shared.present(tab: .license)
        }
    }
}

/// Where the reminder's record is kept. A release build keeps it in preferences, as two plain dates
/// that `defaults write … -date` can set, which is how a beta tester fakes the thirty days (docs/
/// RELEASING.md). A Debug build keeps it in memory only, so a preview never touches the real record.
struct LicenseReminderRecords {
    let defaults: UserDefaults?

    static var forThisBuild: LicenseReminderRecords {
        LicenseReminderRecords(defaults: LicensingSwitch.isDebugBuild ? nil : .standard)
    }

    func load() -> LicenseReminderRecord {
        guard let defaults else { return LicenseReminderRecord() }
        return LicenseReminderRecord(
            graceStart: defaults.object(forKey: AppPreferences.Keys.licenseGraceStart) as? Date,
            lastShown: defaults.object(forKey: AppPreferences.Keys.licenseReminderLastShown) as? Date
        )
    }

    func save(_ record: LicenseReminderRecord) {
        guard let defaults else { return }
        defaults.set(record.graceStart, forKey: AppPreferences.Keys.licenseGraceStart)
        defaults.set(record.lastShown, forKey: AppPreferences.Keys.licenseReminderLastShown)
    }
}
