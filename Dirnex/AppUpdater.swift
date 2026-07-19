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
/// It is also the updater's `SPUUpdaterDelegate`, purely to answer `allowedChannels(for:)` — which
/// is why it is an `NSObject` (Sparkle's delegate protocol refines `NSObject`). That one hook is
/// how the opt-in beta channel reaches Sparkle; everything else is left to the standard controller.
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
    }

    /// Whether a real updater came up. The menu item greys out when it did not.
    var isEnabled: Bool { updaterController != nil }

    /// Run a user-initiated update check (App menu ▸ Check for Updates…, or the ⌘K command).
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
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
