import AppKit
import DirnexCore

/// The explain-and-deep-link half of the Full Disk Access onboarding (PLAN.md §M7 "Full Disk Access
/// onboarding flow (detect, explain, deep-link to System Settings)"). The detection lives in
/// `FullDiskAccessChecker`; this is the surface that turns a `.denied` verdict into a sheet the user
/// can act on — a plain explanation of what the grant unlocks, and a button that opens the exact
/// System Settings pane with Dirnex ready to switch on.
///
/// It is deliberately an `NSAlert` sheet rather than a bespoke window: it is a single-decision
/// surface (grant it, or not now), it matches the alert-driven modals the rest of the app uses, and
/// `enableEscapeToCancel` gives it the same escape-hatch every other Dirnex sheet has.
@MainActor
enum FullDiskAccessOnboarding {
    /// The launch-time policy: offer the grant once on a fresh install where the access is missing,
    /// and never nag afterwards. Silent when the grant is already in place, and silent (but latched)
    /// on every launch after the first. The check is off-main and cheap; the sheet, if any, attaches
    /// to the browser window once it is on screen.
    static func presentIfNeeded(over window: NSWindow?) {
        // Never prompt under `xcodebuild test`: the app test host launches this very delegate, and a
        // first-run modal has no business popping up mid-suite — nor flipping the one-shot latch in
        // the shared defaults. The env var is set by the test host from process start, so it is
        // already true here, before the async check would ever run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !AppPreferences.shared.hasSeenFullDiskAccessOnboarding else { return }
        Task {
            let status = await FullDiskAccessChecker.currentStatus()
            // A machine that already granted access (or pre-granted it before first launch) is left
            // alone and not latched — the next launch re-checks for free and stays just as quiet.
            guard !status.isGranted else { return }
            AppPreferences.shared.hasSeenFullDiskAccessOnboarding = true
            showPrompt(over: window)
        }
    }

    /// The on-demand entry point behind the "Full Disk Access…" menu item and palette command:
    /// always shows something. If the grant is missing it shows the same prompt as first launch; if
    /// it is already in place it says so, so the command is never a no-op the user can't read.
    static func present(over window: NSWindow?) {
        Task {
            let status = await FullDiskAccessChecker.currentStatus()
            AppPreferences.shared.hasSeenFullDiskAccessOnboarding = true
            if status.isGranted {
                showAlreadyGranted(over: window)
            } else {
                showPrompt(over: window)
            }
        }
    }

    // MARK: - The sheets

    private static func showPrompt(over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Give Dirnex Full Disk Access"
        alert.informativeText = """
        Dirnex can browse everywhere, but macOS keeps some folders private — other users' home \
        folders, Mail and Messages, Time Machine backups, and anywhere it considers sensitive. \
        Without Full Disk Access, opening one of those shows a permission wall; everywhere else \
        works normally.

        Click Open System Settings, then switch on Dirnex under Full Disk Access. macOS will ask \
        Dirnex to relaunch so the new access takes effect.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        alert.enableEscapeToCancel() // ⎋ → Not Now; there is no work to lose by declining.

        present(alert, over: window) { response in
            if response == .alertFirstButtonReturn { openSystemSettings() }
        }
    }

    private static func showAlreadyGranted(over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Dirnex already has Full Disk Access"
        alert.informativeText = "You can browse every folder on this Mac. "
            + "To change this, open Full Disk Access in System Settings."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open System Settings")
        alert.enableEscapeToCancel() // ⎋ → OK (the lone safe default here).

        present(alert, over: window) { response in
            if response == .alertSecondButtonReturn { openSystemSettings() }
        }
    }

    // MARK: - Plumbing

    /// Open Privacy & Security ▸ Full Disk Access with the pane already selected. The URL is the
    /// core's pinned constant; `NSWorkspace.open` brings System Settings forward.
    private static func openSystemSettings() {
        guard let url = URL(string: FullDiskAccess.systemSettingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Run the alert as a sheet over `window` when there is one, or as a standalone modal when there
    /// isn't (e.g. every browser window closed but the app is still up), so the prompt is never lost.
    private static func present(
        _ alert: NSAlert,
        over window: NSWindow?,
        then handle: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
