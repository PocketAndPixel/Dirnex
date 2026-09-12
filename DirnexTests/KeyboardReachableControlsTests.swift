import AppKit
import Testing

@testable import Dirnex

/// Tab reaching a dialog's popups, checkboxes, buttons and segmented controls with the system's
/// Keyboard navigation switch off.
///
/// The observable is the key view loop itself — `selectKeyView(following:)` from a field, the call a
/// Tab in a field editor ends in — rather than `canBecomeKeyView` alone, since a control that answers
/// `true` and is still skipped would be the bug with a green test. The narrowness half is the browser
/// window, which must keep its controls out of the loop, and a control nobody can use.
///
/// Everything here assumes the switch is off, which is the macOS default and the only state in which
/// the opt-in changes anything; with it on, AppKit already answers `true` for every one of these.
@Suite(
    "Keyboard-reachable dialog controls",
    .enabled { await MainActor.run { !NSApp.isFullKeyboardAccessEnabled } }
)
@MainActor
struct KeyboardReachableControlsTests {
    private final class PaneKeyController: NSWindowController, PaneKeyWindowController {}

    private struct Form {
        let window: NSWindow
        let first: NSTextField
        let popup: NSPopUpButton
        let checkbox: NSButton
        let segments: NSSegmentedControl
        let push: NSButton
        /// Held here because a window does not retain its controller.
        let controller: NSWindowController?
    }

    /// A field followed by one of each control, stacked in a window of its own.
    private func form(controller: NSWindowController? = nil) -> Form {
        KeyboardReachableControls.install()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let first = NSTextField(string: "host")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["SMB", "SFTP"])
        let checkbox = NSButton(checkboxWithTitle: "Save", target: nil, action: nil)
        let segments = NSSegmentedControl(
            labels: ["A", "B"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        let push = NSButton(title: "Connect", target: nil, action: nil)
        let stack = NSStackView(views: [first, popup, checkbox, segments, push])
        stack.orientation = .vertical
        window.contentView = stack
        if let controller { controller.window = window }
        window.layoutIfNeeded()
        window.recalculateKeyViewLoop()
        return Form(
            window: window,
            first: first,
            popup: popup,
            checkbox: checkbox,
            segments: segments,
            push: push,
            controller: controller
        )
    }

    /// The views Tab visits after `start`, in order, until the loop comes back round.
    private func tabStops(in window: NSWindow, from start: NSView) -> [NSView] {
        var stops: [NSView] = []
        var current = start
        for _ in 0..<12 {
            window.selectKeyView(following: current)
            guard var next = window.firstResponder as? NSView else { break }
            if let editor = next as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
                next = field
            }
            if next === start || stops.contains(where: { $0 === next }) { break }
            stops.append(next)
            current = next
        }
        return stops
    }

    @Test("Tab from a field reaches the popup, checkbox, segmented control and button in a dialog")
    func tabReachesEveryControl() {
        let form = form()
        let stops = tabStops(in: form.window, from: form.first)
        #expect(stops.contains { $0 === form.popup })
        #expect(stops.contains { $0 === form.checkbox })
        #expect(stops.contains { $0 === form.segments })
        #expect(stops.contains { $0 === form.push })
    }

    @Test("an NSAlert's accessory popup and its own buttons are on the Tab loop")
    func alertAccessoryIsReachable() {
        KeyboardReachableControls.install()
        let alert = NSAlert()
        alert.messageText = "Pack"
        alert.addButton(withTitle: "Pack")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "archive")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["zip", "7z"])
        let accessory = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        accessory.orientation = .vertical
        accessory.addArrangedSubview(field)
        accessory.addArrangedSubview(popup)
        alert.accessoryView = accessory
        alert.layout()
        let stops = tabStops(in: alert.window, from: field)
        #expect(stops.contains { $0 === popup })
        #expect(stops.contains { $0 === alert.buttons[0] })
    }

    @Test("NSPopUpButton inherits the opt-in rather than overriding canBecomeKeyView itself")
    func popupInheritsFromButton() {
        let form = form()
        #expect(form.popup.canBecomeKeyView)
    }

    @Test("the browser window keeps its controls off the Tab loop, where Tab is a pane key")
    func paneKeyWindowIsLeftAlone() {
        let form = form(controller: PaneKeyController())
        #expect(form.window.windowController is PaneKeyWindowController)
        let stops = tabStops(in: form.window, from: form.first)
        #expect(!stops.contains { $0 === form.popup })
        #expect(!stops.contains { $0 === form.checkbox })
        #expect(!stops.contains { $0 === form.push })
        #expect(!form.segments.canBecomeKeyView)
    }

    @Test("a disabled or hidden control is not a Tab stop")
    func unusableControlsAreSkipped() {
        let form = form()
        form.popup.isEnabled = false
        form.checkbox.isHidden = true
        #expect(!form.popup.canBecomeKeyView)
        #expect(!form.checkbox.canBecomeKeyView)
        #expect(form.push.canBecomeKeyView)
    }
}
