import AppKit
import DirnexCore
import Foundation
import Sparkle

/// Updates the license doesn't cover (PLAN.md §M29 "Updates for a key whose period has ended").
///
/// Everyone keeps getting updates. The one change: before a version the key doesn't cover is
/// installed, Dirnex says so once, with **Renew**, **Update Anyway** and **Not Now**. Sparkle's
/// `shouldProceedWithUpdate` hook (in `AppUpdater`) asks `gate(…)`, which answers with
/// `UpdateCoverageGate`:
///
/// - a background check of such a version is stopped silently, so Sparkle never downloads or
///   installs it on its own;
/// - a user-initiated check is stopped too, and `UpdateCoverageAlert` comes up once it has ended;
/// - Dirnex's own probe goes on, so the titlebar indicator still says an update exists, and clicking
///   it brings the notice.
///
/// **Update Anyway** lets that build through for the rest of the run and checks again, which brings
/// Sparkle's own update window. How each answer behaves in Sparkle was probed first (docs/NOTES.md ▸
/// Release pipeline).
struct PendingCoverageNotice: Equatable {
    let notice: UpdateCoverageNotice
    /// The update's `sparkle:version`, which **Update Anyway** allows.
    let build: String
}

extension AppUpdater {
    /// The error Sparkle ends a check on without showing anything. Any other error puts Sparkle's
    /// own error alert in front of the user (probed, docs/NOTES.md ▸ Release pipeline).
    nonisolated static var heldBack: NSError {
        NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.installationCanceledError.rawValue),
            userInfo: [
                NSLocalizedDescriptionKey: "Held back: the license doesn't cover this update."
            ]
        )
    }

    /// The hook's answer: returns to let Sparkle go on, throws ``heldBack`` to stop the check.
    /// Separate from the witness because an `SUAppcastItem` can't be made in a test without a
    /// deprecated initializer.
    nonisolated func gate(
        version: String,
        build: String,
        releaseDate: Date?,
        check: SPUUpdateCheck
    ) throws {
        let kind: UpdateCheckKind = switch check {
        case .updates: .userInitiated
        case .updatesInBackground: .background
        case .updateInformation: .probe
        // A kind this Sparkle doesn't have yet is held back without a word, never installed.
        @unknown default: .background
        }
        // Sparkle calls this on the main thread (probed). If a future version doesn't, a build with
        // licensing on holds back anything that could install rather than trap, and a dormant build
        // updates as it always did.
        guard Thread.isMainThread else {
            if licensingIsOn, kind != .probe { throw Self.heldBack }
            return
        }
        let proceeds = MainActor.assumeIsolated {
            decide(version: version, build: build, releaseDate: releaseDate, kind: kind)
        }
        if !proceeds { throw Self.heldBack }
    }

    /// Whether the check goes on, noting the notice to show when it doesn't and the user is there.
    private func decide(version: String, build: String, releaseDate: Date?, kind: UpdateCheckKind) -> Bool {
        // A build that shows nothing about licenses holds nothing back either.
        guard licensingIsOn else { return true }
        let notice = UpdateCoverageNotice.notice(
            key: licenseStore.key,
            currentReleaseDay: licenseStore.buildReleaseDay,
            updateVersion: version,
            updateReleaseDay: releaseDate.map { LicenseDay($0, in: .gmt) }
        )
        switch coverageGate.decision(notice: notice, build: build, check: kind) {
        case .proceed:
            return true
        case .holdBack:
            return false
        case let .notify(notice):
            pendingCoverageNotice = PendingCoverageNotice(notice: notice, build: build)
            return false
        }
    }

    /// Shows the notice a check was held back for, if any. Called once the check has ended.
    func presentPendingCoverageNotice() {
        guard let pending = pendingCoverageNotice else { return }
        pendingCoverageNotice = nil
        Task {
            // The browser window, like the reminder and the license link, rather than
            // `NSApp.mainWindow`, which is nil while Dirnex is in the background: a check the user
            // started can end after they switched away, and the notice should wait on the window.
            let window = (NSApp.delegate as? AppDelegate)?.activeBrowserWindowController?.window
            let choice = await UpdateCoverageAlert.present(pending.notice, over: window)
            handle(choice, for: pending)
        }
    }

    /// Acts on the choice made in the notice. Internal for the tests.
    func handle(_ choice: UpdateCoverageAlert.Choice, for pending: PendingCoverageNotice) {
        switch choice {
        case .notNow:
            // The indicator stays lit: a held-back check never reports "no update".
            break
        case .updateAnyway:
            coverageGate.allow(build: pending.build)
            checkForUpdates()
        case .renew:
            if let key = licenseStore.key {
                NSWorkspace.shared.open(LicenseLinks.renew(key))
            }
        }
    }
}
