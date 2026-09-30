import AppKit
import Quartz

/// Getting the shared Quick Look panel (⌘Y) out of the way of a sheet.
///
/// `QLPreviewPanel` is a *floating* panel and it is not this window's, so a sheet cannot cover it and
/// cannot keep the keyboard away from it. Both halves of that bite, and they compound: a
/// confirmation raised while a preview is open opens **behind** the panel — measured once as
/// completely hidden but for a sliver of the default button — and clicking the panel to move it
/// aside is then what makes the sheet keyboard-dead, because key focus goes to the panel and stays
/// there. Return lands on a panel with no default button and beeps, while the sheet goes on drawing
/// its Delete button as the default and answering the mouse. That combination is why it reads as
/// "the Enter key isn't bound" rather than as a focus problem, and why it is intermittent: ⌘Y → ⇧F8
/// → ⏎ works (the sheet takes key as it opens), and ⌘Y → ⇧F8 → *click the panel* → ⏎ does nothing.
/// Reported live 2026-08-09 against the permanent-delete confirmation.
///
/// One observer rather than a line at each of the ~40 `beginSheetModal` sites: every sheet this
/// window raises posts `willBeginSheetNotification`, including ones added later. The preview does
/// not come back afterwards — ⌘Y reopens it, and restoring it over a file the sheet may have just
/// deleted is the worse surprise.
extension BrowserWindowController {
    /// Start closing the Quick Look panel whenever this window is about to show a sheet.
    ///
    /// Selector-based, so the `nonisolated deinit`'s `removeObserver(self)` can tear it down
    /// (docs/NOTES.md — a token array is not `Sendable`).
    func installQuickLookSheetGuard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dismissQuickLookForSheet),
            name: NSWindow.willBeginSheetNotification,
            object: window
        )
    }

    @objc private func dismissQuickLookForSheet() {
        Self.dismissSharedQuickLookPanel()
    }

    /// Order the shared preview panel out, if one is on screen; `true` when it closed one.
    ///
    /// `sharedPreviewPanelExists()` has to come first: `shared()` *creates* the panel, so an
    /// unguarded call would conjure one on every sheet in a session where Quick Look was never
    /// opened. Static so the behavior can be exercised without standing up a whole browser window.
    @discardableResult
    static func dismissSharedQuickLookPanel() -> Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let previewPanel = QLPreviewPanel.shared(),
              previewPanel.isVisible else { return false }
        previewPanel.orderOut(nil)
        return true
    }
}
