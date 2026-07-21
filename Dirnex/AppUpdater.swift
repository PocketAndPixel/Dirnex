import AppKit
import DirnexCore
import Foundation
import Sparkle

/// Owns the Sparkle updater and bridges it to Dirnex's registry-driven command dispatch
/// (PLAN.md §M7 "Sparkle 2 updates" + "Beta + stable update channels").
///
/// The rest of the app never imports Sparkle — it asks for `app.checkForUpdates`, and this is the
/// one place that turns that into an `SPUUpdater` check. The controller is built lazily and only
/// when three things hold, so the same code is safe in every build:
///
/// - the bundle actually carries a feed URL and public key (`SUFeedURL`/`SUPublicEDKey`), so a
///   misconfigured build degrades to a disabled menu item rather than a crash;
/// - we are not inside an `xcodebuild test` run — the app test host launches the real delegate
///   (the same reason `FirstRunTourPresenter`/FDA guard on `XCTestConfigurationFilePath`), and a
///   live updater there would reach the network and pop Sparkle's permission prompt mid-suite.
///
/// It is also the updater's `SPUUpdaterDelegate` — which is why it is an `NSObject` (Sparkle's
/// delegate protocol refines `NSObject`). Two things ride on that: `allowedChannels(for:)`, how the
/// opt-in beta channel reaches Sparkle, and the found/not-found/user-choice callbacks that keep
/// `availability` current for the titlebar indicator. Everything else is left to the standard
/// controller — except the scheduling, which Dirnex owns: see `startProbing()` for why Sparkle's own
/// scheduler cannot be what keeps the indicator honest.
///
/// Sparkle is still *compiled* in every configuration (the type is never `#if`-d out), so the Debug
/// `xcodebuild test` job catches any misuse of the update API even though it never starts it.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    // A `var` only because two-phase init forbids passing `self` as the delegate before
    // `super.init()`; it is assigned exactly once, right after, and never mutated again.
    private var updaterController: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        super.init()
        guard !Self.isRunningTests, Self.hasUpdateConfiguration(bundle: bundle) else {
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        startProbing()
    }

    /// Whether a real updater came up. The menu item greys out when it did not.
    var isEnabled: Bool { updaterController != nil }

    /// Posted whenever `availability` changes, so the titlebar indicator can restyle itself. No
    /// payload — observers read `availability` off the posting `AppUpdater` (the notification's
    /// object), which is the app delegate's single instance.
    static let availabilityDidChange = Notification.Name("Dirnex.updateAvailabilityDidChange")

    /// Whether a newer build is waiting, and which one (`DirnexCore.UpdateAvailability`). Driven
    /// entirely by the Sparkle callbacks below; the titlebar button in `BrowserWindowController`
    /// mirrors it. Starts empty — the launch probe below is what can raise it.
    private(set) var availability: UpdateAvailability = .none {
        didSet {
            guard availability != oldValue else { return }
            NotificationCenter.default.post(name: Self.availabilityDidChange, object: self)
        }
    }

    /// Run a user-initiated update check (App menu ▸ Check for Updates…, or the ⌘K command).
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    // MARK: - Background probe

    /// The one-shot timer carrying the next probe. One-shot rather than repeating so each probe
    /// re-derives its own successor from `schedule` — a repeating timer would drift and, worse,
    /// could not be re-aimed when an activation probe lands early.
    private var probeTimer: Timer?

    /// When the last probe went out, for this process only. Deliberately not persisted: the launch
    /// probe is unconditional, so the only consumer is the activation catch-up below, and a date on
    /// disk would just be a second source of truth for a decision that can't outlive the process.
    private var lastProbe: Date?

    private let schedule = UpdateCheckSchedule()

    /// Probe now, then keep probing on `schedule` (PLAN.md §M7).
    ///
    /// This exists because Sparkle's own scheduler cannot be relied on to keep the indicator honest:
    /// its automatic checks sit behind the first-run permission prompt, and an install that answered
    /// "no" has `SUEnableAutomaticChecks = 0` forever — no scheduled check, no `didFindValidUpdate`,
    /// and an indicator that stays dark through every release. Observed on a real install: a build
    /// three days stale with a beta waiting in the feed and nothing on screen.
    ///
    /// Only ever reached when a real updater came up, so the guards in `init` cover this too — no
    /// timer is armed under `xcodebuild test` or in a build with no feed configured.
    private func startProbing() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        runProbe()
    }

    /// A timer does not fire while the machine is asleep, so a laptop opened after a night comes
    /// back with an armed timer that is hours overdue and will not fire until its original fire date
    /// passes. Re-asking on activation is what makes the first thing the user sees after waking a
    /// current answer rather than yesterday's.
    @objc private func applicationDidBecomeActive() {
        guard schedule.isDue(lastCheck: lastProbe, now: Date()) else { return }
        runProbe()
    }

    /// One silent check. `checkForUpdateInformation()` is Sparkle's *probing* check: it runs the real
    /// appcast fetch through this same delegate — so `allowedChannels(for:)` still applies and a beta
    /// opt-in is honoured — but it presents no UI whatsoever. All it does here is drive
    /// `availability`, which lights the titlebar glyph; clicking that glyph is what opens Sparkle's
    /// actual install flow. A check the user did not ask for must never put a window on their screen.
    private func runProbe() {
        guard let updater = updaterController?.updater else { return }
        lastProbe = Date()
        // Sparkle documents the probe as a no-op while another check or install is in flight. Count
        // it as taken anyway: the user is already inside Sparkle's UI, which feeds `availability`
        // through the very same callbacks, and rescheduling a zero-delay retry instead would spin.
        if !updater.sessionInProgress {
            updater.checkForUpdateInformation()
        }
        scheduleNextProbe()
    }

    private func scheduleNextProbe() {
        probeTimer?.invalidate()
        let delay = schedule.delayUntilNextCheck(lastCheck: lastProbe, now: Date())
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            // A main-runloop timer fires on the main thread by construction, so the assumption holds.
            MainActor.assumeIsolated { self?.runProbe() }
        }
        // `.common` rather than the default mode: a probe owed while a menu is open or a split view
        // is being dragged should still go out, not wait for the tracking loop to end.
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    // MARK: - SPUUpdaterDelegate

    /// The extra channels this install may look in, asked by Sparkle on every check. `nonisolated`
    /// with a direct `UserDefaults` read (see `AppPreferences.receiveBetaUpdatesValue`) rather than
    /// touching the `@MainActor` `AppPreferences.shared`: the hook is called synchronously inside
    /// the check, and the persisted key is safe to read from any thread and can't drift from what
    /// Settings wrote. Re-reading here is what lets the Settings toggle take effect without a
    /// relaunch — `UpdateChannels.allowed` maps the opt-in to `["beta"]` or `[]`.
    nonisolated func allowedChannels(for _: SPUUpdater) -> Set<String> {
        UpdateChannels.allowed(receiveBetaUpdates: AppPreferences.receiveBetaUpdatesValue())
    }

    /// A check turned up a newer build — whether the user asked for it or Sparkle's scheduler did.
    /// Raising the indicator here is what makes a *background* find visible at all beyond the moment
    /// its dialog is on screen.
    nonisolated func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setAvailability(.available(version: item.displayVersionString))
    }

    /// A check came back empty: whatever the indicator was showing is gone (the user installed it
    /// from another window, or the release was pulled).
    nonisolated func updaterDidNotFindUpdate(_: SPUUpdater) {
        setAvailability(.none)
    }

    /// The user answered Sparkle's dialog. Only `dismiss` leaves the indicator standing — see
    /// `UpdateAvailability.afterUserChoice`, which owns that policy.
    nonisolated func updater(
        _: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate _: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        let mapped: UpdateChoice = switch choice {
        case .install: .install
        case .skip: .skip
        case .dismiss: .dismiss
        @unknown default: .dismiss
        }
        setAvailabilityAfter(mapped)
    }

    // MARK: - Main-actor hop

    /// `SPUUpdater` is documented main-thread-only, so its delegate callbacks arrive on the main
    /// thread and the assumption below holds — but the protocol witnesses must be `nonisolated`
    /// under Swift 6, so the isolation has to be re-established somewhere. Asserting it (rather than
    /// hopping unconditionally) keeps each callback's effect synchronous and ordered; the `Task`
    /// fallback means a future Sparkle calling from elsewhere lands the change a runloop late
    /// instead of trapping in a shipping build.
    private nonisolated func setAvailability(_ newValue: UpdateAvailability) {
        onMain { $0.availability = newValue }
    }

    private nonisolated func setAvailabilityAfter(_ choice: UpdateChoice) {
        onMain { $0.availability = $0.availability.afterUserChoice(choice) }
    }

    private nonisolated func onMain(_ body: @escaping @MainActor (AppUpdater) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            Task { @MainActor in body(self) }
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// True only when the bundle carries both a non-empty feed URL and public key. Debug/dev builds
    /// carry them too (they are committed in `Info.plist`), so updates work while dogfooding; a
    /// build that stripped them just disables the feature.
    private static func hasUpdateConfiguration(bundle: Bundle) -> Bool {
        guard
            let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
