import AppKit
import SwiftUI
import Testing

@testable import Dirnex

/// Escape closes Settings while a text field is being edited.
///
/// Reported 2026-10-11: on Settings ▸ License, whose key field holds the focus, Escape beeped and the
/// window stayed. The monitor stood aside for any field editor, on the belief that Escape reverts
/// the edit, and a SwiftUI `TextField` does nothing with it. These run on the real License tab,
/// because the field editor SwiftUI installs there is the responder the monitor sees.
///
/// Each test makes the predicate answer both ways on the same editor, so an editor that never took
/// the focus can't pass for one the monitor closes over.
@Suite("Settings Escape")
@MainActor
struct SettingsEscapeTests {
    private func licenseWindow() -> NSWindow {
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LicenseSettingsView(store: store))
        return window
    }

    /// The key field's editor, after focusing the field: what the monitor reads as first responder.
    ///
    /// 30 s, like the shared `settleUntil`, with one last look after the deadline: in a full run the
    /// main actor stalls for seconds at a time (docs/NOTES.md ▸ Testing).
    private func keyFieldEditor(in window: NSWindow) async throws -> NSTextView {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func find() -> NSTextField? {
            window.contentView.map(all)?.compactMap { $0 as? NSTextField }.first(where: \.isEditable)
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while find() == nil, ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let field = try #require(find())
        #expect(window.makeFirstResponder(field))
        return try #require(window.firstResponder as? NSTextView)
    }

    @Test("a focused key field with text in it leaves Escape to close Settings")
    func editingClosesSettings() async throws {
        let window = licenseWindow()
        defer { window.close() }
        let editor = try await keyFieldEditor(in: window)
        editor.insertText("dnx1.half-pasted", replacementRange: editor.selectedRange())
        #expect(editor.string == "dnx1.half-pasted")
        #expect(!EscapeToCloseMonitor.leavesEscape(to: window.firstResponder))

        // The control on the same editor: a responder that does own Escape is still left alone.
        editor.setMarkedText(
            "か",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(EscapeToCloseMonitor.leavesEscape(to: window.firstResponder))
    }

    /// Escape cancels an input method's composition (Japanese, Chinese, Korean), and closing the
    /// window over it would throw the half-typed word away along with the window.
    @Test("an input method's composition keeps Escape, and gives it back once committed")
    func compositionKeepsEscape() async throws {
        let window = licenseWindow()
        defer { window.close() }
        let editor = try await keyFieldEditor(in: window)
        editor.setMarkedText(
            "にほ",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(editor.hasMarkedText())
        #expect(EscapeToCloseMonitor.leavesEscape(to: window.firstResponder))

        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        #expect(!EscapeToCloseMonitor.leavesEscape(to: window.firstResponder))
    }
}
