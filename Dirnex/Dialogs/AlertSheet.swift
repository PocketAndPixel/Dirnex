import AppKit

/// Running an `NSAlert` **attached to the app** rather than floating over the screen.
///
/// `runModal()` centers an alert on the *display*, not on the window that raised it — measured on a
/// 1728 pt screen, a 260 pt alert lands at x=734 whatever the window's frame is. So a confirmation
/// raised from a pane appears detached from the app, in a place the user's eyes are not, and on a
/// large display it can be nowhere near the window it belongs to. Every alert that has a window to
/// hang on should be a sheet; `runModal()` is the fallback for the one case that has none.
///
/// The reason a handful of alerts were written the other way is real, and it is what
/// ``sheetHost(over:)`` exists to solve: **stacking a second sheet on a window that already has one
/// queues it behind the first, where nobody sees it.** Probed directly — the second alert's window
/// reports `isVisible == false` and the window's `attachedSheet` is still the first — so a trust
/// prompt raised from inside the Connect sheet's own attempt would simply never appear, deadlocking
/// a flow that is waiting on its answer. Hosting it on the **sheet's** window instead works: it is
/// visible, attached, and centered on its host.
extension NSAlert {
    /// The surface an alert should hang on: whatever is in front of `window`, else the window.
    ///
    /// `NSApp.modalWindow` is asked first because some of the app's dialogs are app-modal *windows*
    /// (`presentAsModalWindow`), not sheets, so they are not their parent's `attachedSheet` — and an
    /// alert hung on the browser window while one of those is up is an alert the user cannot click.
    /// The `attachedSheet` question then covers every sheet-shaped dialog. Returns `nil` only when
    /// there is no window at all.
    static func sheetHost(over window: NSWindow?) -> NSWindow? {
        NSApp.modalWindow ?? window?.attachedSheet ?? window
    }

    /// Present as a sheet where the user can see it — and **not at all** when there is no window.
    ///
    /// The `runModal()` fallback above is right for an alert a *user is waiting on*: they pressed
    /// something, and an answer detached from the app beats no answer. It is wrong for the third
    /// kind, the one this method serves — an alert the **app** raises unasked, on its own schedule:
    /// a listing that failed during a navigation the app started, a queued job finishing minutes
    /// later, a watcher noticing an editor's save. Nobody is waiting for those, so with no window
    /// there is nobody to tell, and `runModal` does not merely misplace the alert — it **blocks the
    /// process** on a dialog that arrived by itself.
    ///
    /// That is not hypothetical: it is how the app's own test host came to raise six app-modal
    /// alerts in one run, each stalling the suite until a human clicked OK, which read as an
    /// unrelated live test timing out (2026-08-14, found by the user watching the screen — see
    /// docs/NOTES.md ▸ Testing). The same state is reachable in the app during launch restoration,
    /// before `showWindow`.
    ///
    /// Hosting goes through ``sheetHost(over:)`` like every other sheet, so a report landing while a
    /// dialog is up attaches to *that* dialog rather than being queued invisibly behind it.
    func beginSheetIfVisible(
        over window: NSWindow?,
        completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        guard let host = NSAlert.sheetHost(over: window) else { return }
        beginSheetModal(for: host, completionHandler: completionHandler)
    }

    /// The `await` spelling of ``beginSheetIfVisible(over:completionHandler:)`` — and the reason it
    /// is not ``runSheet(over:onPresented:)`` is the one that method's own fallback line makes.
    ///
    /// `runSheet` answers a windowless caller with `runModal()`, which is right for an alert a user
    /// pressed something to get and **wrong for one a watcher raised**: it blocks the process on a
    /// dialog that arrived by itself. So this one asks nobody and answers `whenUnasked`.
    ///
    /// The caller has to name that answer rather than getting a default, because it is a decision
    /// about the user's files: for a save-back it is "upload nothing", which leaves the copy watched
    /// so the next save asks again — never a silent yes to a question that was never put.
    ///
    /// One `resume` on every path, which is the whole hazard here: the non-async spelling simply
    /// returns when there is no host, and a continuation wrapped around it would wait forever.
    func sheetAnswer(
        over window: NSWindow?,
        whenUnasked: NSApplication.ModalResponse
    ) async -> NSApplication.ModalResponse {
        guard let host = NSAlert.sheetHost(over: window) else { return whenUnasked }
        return await withCheckedContinuation { continuation in
            beginSheetModal(for: host) { continuation.resume(returning: $0) }
        }
    }

    /// Present as a sheet on ``sheetHost(over:)`` and wait for the answer.
    ///
    /// `onPresented` runs once the sheet is up, for the one thing a sheet cannot do for itself:
    /// `selectText(nil)` on an accessory field, so a prefilled name is selected and typing replaces
    /// it. (`initialFirstResponder` gets the *focus* there; only this selects the text.) On the
    /// windowless fallback it runs just before the modal loop, which is the closest equivalent
    /// available — nothing can run *during* `runModal`.
    func runSheet(
        over window: NSWindow?,
        onPresented: (() -> Void)? = nil
    ) async -> NSApplication.ModalResponse {
        guard let host = NSAlert.sheetHost(over: window) else {
            onPresented?()
            return runModal()
        }
        return await withCheckedContinuation { continuation in
            beginSheetModal(for: host) { continuation.resume(returning: $0) }
            onPresented?()
        }
    }
}
