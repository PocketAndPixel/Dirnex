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
