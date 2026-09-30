import AppKit
import Testing

@testable import Dirnex

/// When closing the last window is allowed to quit Dirnex.
///
/// AppKit does not answer that question at the moment a window closes. It schedules a deferred check
/// on a main-run-loop **timer** and asks whenever that run loop is next pumped — so the question can
/// arrive while `applicationDidFinishLaunching` is still on the stack, before `showWindow`, when the
/// browser window exists but nothing is visible yet. Answering a blanket `true` there means "no
/// windows left, quit" to what is really "no windows *yet*", and the app terminates itself
/// mid-launch with exit code 0 and no crash report. That is what made `xcodebuild test` fail roughly
/// half the time: the test bundle is injected during launch and XCTest runs its own run loop, so the
/// timer landed inside the launch window and quit the host mid-suite, reporting every test still in
/// flight as a failure it never was.
///
/// **The claim is pinned on a delegate this test builds, not on the running app's**, and that is the
/// whole design of the suite. The obvious version — read `NSApp.delegate`'s window, then assert —
/// was written first and is unsound: measured over six runs, `applicationDidFinishLaunching` does not
/// complete at all in **half** of them (the suite outruns it, and XCTest exits the host when it is
/// done), so the window is simply absent and the assertion fails for a reason that has nothing to do
/// with the policy. A guard that flakes half the time is the exact disease this fix was treating.
/// A freshly constructed delegate is the pre-`showWindow` state, deterministically and with no
/// waiting, which is precisely the state that used to authorize the quit.
///
/// What that leaves uncovered is worth stating rather than faking, because the fix's *other* failure
/// mode is over-correction — a blanket `false`, or a guard keyed on `XCTestConfigurationFilePath` —
/// which would ship an app that no longer quits when its window is closed. No assertion here can
/// tell those from the real thing: with no window built, all three answer `false`, and the state
/// that separates them (`browserWindowController` filled) is private and reachable only by a real
/// launch. Both were nonetheless run against this suite by hand, and the live app was checked to
/// still quit on ⌘W. The invariant below is the half a test can hold honestly.
@Suite("App termination policy")
@MainActor
struct AppTerminationPolicyTests {
    /// A delegate that has not built its window yet must not authorize the quit. The pre-fix code
    /// was a bare `true`, which fails this.
    @Test("before the browser window exists, the last-window-closed check says no")
    func doesNotQuitBeforeTheWindowExists() {
        #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }
}
