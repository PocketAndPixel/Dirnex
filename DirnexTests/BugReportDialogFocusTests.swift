import AppKit
import Testing

@testable import Dirnex

/// Where the Report a Bug dialog's focus goes: Tab between its boxes, a click into one, and Escape.
///
/// Its own suite because `BugReportDialogTests` reached SwiftLint's `type_body_length` when the click
/// test arrived. Nothing here sends, so nothing here touches `BugReportStubProtocol`, whose state that
/// suite serializes.
@Suite("Bug report dialog: where the focus goes")
@MainActor
struct BugReportDialogFocusTests {
    @Test("Escape is Cancel's, and Tab leaves the description instead of typing a tab")
    func escapeAndTab() throws {
        let dialog = BugReportDialogTests.dialog()
        let controller = dialog.controller
        #expect(controller.cancelButton.keyEquivalent == "\u{1b}")
        dialog.window.orderFront(nil)
        defer { dialog.window.close() }
        #expect(dialog.window.firstResponder === controller.descriptionView)
        controller.descriptionView.insertTab(nil)
        #expect(dialog.window.firstResponder === controller.stepsView)
        #expect(controller.descriptionView.string.isEmpty)
        controller.stepsView.insertBacktab(nil)
        #expect(dialog.window.firstResponder === controller.descriptionView)
    }

    /// What was measured live on 2026-10-24 with real clicks while Finder was active: one click into
    /// Steps left the focus in the email field, and one into the email field focused it. A press into
    /// a window that isn't key takes that path (`MultiLineFieldTests`), and the email field is the
    /// control: it takes the click in AppKit's own code. Negative control: with `MultiLineTextView`
    /// answering `false`, both boxes fail and the email field still passes.
    ///
    /// **Each press has a dialog of its own.** On CI the test host can be the active app, where a
    /// window can be key after its first press: on 2026-10-28 one window pressed three times there
    /// failed the check before a press. Here the host is never active, so its windows are never key.
    @Test("one click from another app focuses the box it lands in, as it does the email field")
    func clickFromAnotherApp() throws {
        try press(\.stepsView, from: \.emailField) { controller, window in
            #expect(window.firstResponder === controller.stepsView)
        }
        try press(\.descriptionView, from: \.emailField) { controller, window in
            #expect(window.firstResponder === controller.descriptionView)
        }
        try press(\.emailField, from: \.stepsView) { controller, window in
            let editor = try #require(controller.emailField.currentEditor())
            #expect(window.firstResponder === editor)
        }
    }

    /// One press into `target`, in a dialog of its own shown with the focus in `start`, then `check`.
    private func press<Target: NSView, Start: NSResponder>(
        _ target: KeyPath<BugReportController, Target>,
        from start: KeyPath<BugReportController, Start>,
        check: (BugReportController, NSWindow) throws -> Void
    ) throws {
        let dialog = BugReportDialogTests.dialog()
        let controller = dialog.controller
        let window = dialog.window
        window.orderFront(nil)
        defer {
            window.close()
            NSApp.discardEvents(matching: .leftMouseUp, before: nil)
        }
        window.makeFirstResponder(controller[keyPath: start])
        try #require(!window.isKeyWindow, "before the press into \(target)")
        try MultiLineFieldTests.click(controller[keyPath: target], in: window)
        try check(controller, window)
    }
}
