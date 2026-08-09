import AppKit
import Quartz
import Testing

@testable import Dirnex

/// The shared Quick Look panel is closed before a sheet goes up.
///
/// `QLPreviewPanel` floats above this window's sheets and can take key focus from one, so a
/// confirmation raised while ⌘Y is open lands *behind* the preview and, once the panel is clicked,
/// stops answering Return entirely — it beeps, while the sheet keeps drawing its default button and
/// keeps answering the mouse. Reproduced live 2026-08-09 as ⌘Y → ⇧F8 → click the panel → ⏎.
///
/// Two of the three claims are not the test target's to make. The **wiring** (one
/// `willBeginSheetNotification` observer, so every sheet is covered) needs a live window, and the
/// **close** cannot be measured here at all: `orderOut` is asynchronous on this panel, and a panel
/// raised in the test host — no controller, no preview items — never reports `isVisible == false`
/// afterwards however long it is polled, so an assertion on it would be measuring the harness.
/// Both are verified by launching. What is pinned here is the half that fails *silently*: the guard
/// must never bring a panel into existence.
@Suite("Quick Look sheet guard")
@MainActor
struct QuickLookSheetGuardTests {
    @Test("it never conjures a preview panel — `shared()` would create one")
    func doesNotCreateAPanel() {
        // Order-independent on purpose: another suite may already have made the shared panel, and
        // the claim — "asking the guard to run does not change whether one exists" — holds either
        // way. Without the `sharedPreviewPanelExists()` gate, every sheet in a session where Quick
        // Look was never opened would build one, with nothing on screen to say so.
        let existedBefore = QLPreviewPanel.sharedPreviewPanelExists()
        let closed = BrowserWindowController.dismissSharedQuickLookPanel()
        #expect(QLPreviewPanel.sharedPreviewPanelExists() == existedBefore)
        if !existedBefore { #expect(!closed) }
    }
}
