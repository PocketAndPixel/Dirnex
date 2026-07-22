import AppKit

/// Decides when the first-run tour appears and what follows it (PLAN.md §M7 "First-run tour"). The
/// window and paging are `FirstRunTourWindowController`'s; this is the launch-time policy and the
/// on-demand entry point — the twin of `FullDiskAccessOnboarding`, and deliberately sequenced *with*
/// it: the tour precedes Full Disk Access onboarding so a stranger meets the welcome before the
/// permission wall, exactly the order the M7 exit criterion walks.
@MainActor
enum FirstRunTourPresenter {
    /// The live tour, held for the duration so it survives to report back; `nil` when none is up.
    private static var controller: FirstRunTourWindowController?

    /// Launch-time policy: on a fresh install, walk the user through the tour once and then hand off
    /// to Full Disk Access onboarding. On every later launch (tour already seen) skip straight to
    /// the FDA check, so its own one-shot first-run behaviour is preserved untouched.
    static func presentIfNeeded(over window: NSWindow?) {
        // Never during `xcodebuild test`: the app test host launches the real delegate, and a
        // first-run window has no business popping up mid-suite or flipping the shared latch. FDA's
        // own guard means skipping the hand-off here leaves it dormant too, which is what we want.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !AppPreferences.shared.hasSeenFirstRunTour else {
            FullDiskAccessOnboarding.presentIfNeeded(over: window)
            return
        }
        AppPreferences.shared.hasSeenFirstRunTour = true
        show(over: window, finalButtonTitle: String(localized: "Get Started"), onPrimary: nil) {
            // Whatever button ended the tour, hand off to the FDA check — the important next step on
            // a fresh install, and the one the exit criterion measures.
            FullDiskAccessOnboarding.presentIfNeeded(over: window)
        }
    }

    /// On-demand entry point behind "Welcome to Dirnex…" (menu + palette): always shows the tour,
    /// whatever the latch. No FDA hand-off — that belongs to the first-run sequence; here the user
    /// opened the tour deliberately, so the last screen offers to drop them into the command palette
    /// instead, the payoff the tour's copy promises.
    static func present(over window: NSWindow?) {
        AppPreferences.shared.hasSeenFirstRunTour = true
        show(over: window, finalButtonTitle: String(localized: "Open Command Palette"), onPrimary: {
            // Dispatched through the responder chain — `AppDelegate` is its final link — after the
            // sheet has closed, so the palette floats over the browser window, not the tour.
            NSApp.sendAction(#selector(AppDelegate.showCommandPalette(_:)), to: nil, from: nil)
        }, then: nil)
    }

    /// Build, wire, and present a tour. `onPrimary` runs only when the user finishes on the last
    /// screen's primary button; `then` runs on every dismissal. Both fire after the controller is
    /// released, so a re-open can't collide with the one that just closed.
    private static func show(
        over window: NSWindow?,
        finalButtonTitle: String,
        onPrimary: (() -> Void)?,
        then: (() -> Void)?
    ) {
        guard controller == nil else { return } // never stack a second tour over a live one
        let controller = FirstRunTourWindowController()
        controller.finalButtonTitle = finalButtonTitle
        controller.onFinish = { primaryChosen in
            self.controller = nil
            if primaryChosen { onPrimary?() }
            then?()
        }
        self.controller = controller
        controller.present(over: window)
    }
}
