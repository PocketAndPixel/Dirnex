import AppKit
import Foundation
import Sparkle

/// Owns the Sparkle updater and bridges it to Dirnex's registry-driven command dispatch
/// (PLAN.md §M7 "Sparkle 2 updates").
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
/// Sparkle is still *compiled* in every configuration (the type is never `#if`-d out), so the Debug
/// `xcodebuild test` job catches any misuse of the update API even though it never starts it.
@MainActor
final class AppUpdater {
    private let updaterController: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        guard !Self.isRunningTests, Self.hasUpdateConfiguration(bundle: bundle) else {
            updaterController = nil
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Whether a real updater came up. The menu item greys out when it did not.
    var isEnabled: Bool { updaterController != nil }

    /// Run a user-initiated update check (App menu ▸ Check for Updates…, or the ⌘K command).
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
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
