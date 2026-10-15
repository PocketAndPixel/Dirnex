import AppKit
import DirnexCore
import SwiftUI
import Testing

@testable import Dirnex

/// The Settings ▸ Shortcuts pill as a keyboard stop: Tab reaches it, it draws a focus ring there, and
/// the keys that press a focused button start a recording.
///
/// Before this, Tab already landed on every pill (it is a key view with Keyboard navigation off too)
/// and showed nothing, Space and Return did nothing, and Escape went nowhere — the pill was marked as
/// owning Escape whether or not it was recording.
///
/// Keys go in the way the app dispatches them: `performKeyEquivalent`, then `sendEvent` if that
/// declined (docs/NOTES.md ▸ Testing). Each key test has a case where a key does nothing, so a key
/// that never arrived can't pass for one that was ignored.
@Suite("Shortcut recorder focus")
@MainActor
struct ShortcutRecorderFocusTests {
    private final class Records {
        var values: [CommandShortcut?] = []
    }

    private struct Fixture {
        let window: NSWindow
        let field: NSTextField
        let first: ShortcutRecorder.RecorderView
        let second: ShortcutRecorder.RecorderView
        let records: Records
    }

    private func window(showing view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    private func views<View: NSView>(_: View.Type, in window: NSWindow) -> [View] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return window.contentView.map(all)?.compactMap { $0 as? View } ?? []
    }

    /// Waits for SwiftUI to build what `find` looks for, laying the window out as it goes, with one
    /// last look after the deadline (docs/NOTES.md ▸ Testing).
    private func built<Found>(in window: NSWindow, _ find: () -> Found?) async throws -> Found? {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let found = find() { return found }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return find()
    }

    /// A field and two pills in a grouped `Form`, as the Shortcuts tab lays them out.
    private func fixture() async throws -> Fixture {
        let records = Records()
        let pill = { (shortcut: CommandShortcut?) in
            ShortcutRecorder(shortcut: shortcut, isConflicting: false) { records.values.append($0) }
                .frame(width: 148, height: 24)
        }
        let newTab = CommandShortcut(key: "t", modifiers: [.command])
        let window = window(
            showing: Form {
                TextField("Filter", text: .constant(""))
                HStack { Text("One"); Spacer(); pill(newTab) }
                HStack { Text("Two"); Spacer(); pill(nil) }
            }
            .formStyle(.grouped)
        )
        let pills = try #require(try await built(in: window) {
            let pills = views(ShortcutRecorder.RecorderView.self, in: window)
            return pills.count == 2 ? pills : nil
        })
        let field = try #require(views(NSTextField.self, in: window).first { $0.isEditable })
        window.recalculateKeyViewLoop()
        return Fixture(
            window: window,
            field: field,
            first: pills[0],
            second: pills[1],
            records: records
        )
    }

    private func key(
        _ keyCode: UInt16,
        _ characters: String,
        _ modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    private func space(in window: NSWindow) throws { try key(49, " ", in: window) }
    /// A real ⇧Tab carries the back-tab character, and AppKit reads Shift with `\t` as a plain Tab.
    private func tab(backward: Bool = false, in window: NSWindow) throws {
        try key(48, backward ? "\u{19}" : "\t", backward ? .shift : [], in: window)
    }

    @Test("Tab from the Filter field lands on a pill, and the pill has a ring to draw")
    func tabLandsOnARingedPill() async throws {
        let fixture = try await fixture()
        fixture.window.selectKeyView(following: fixture.field)
        let pill = try #require(fixture.window.firstResponder as? ShortcutRecorder.RecorderView)
        #expect(pill === fixture.first)
        #expect(!pill.isRecording)
        #expect(pill.focusRingType != .none)
        #expect(pill.focusRingMaskBounds == pill.bounds)
        #expect(!pill.bounds.isEmpty)

        // The mask has to paint something, or the ring AppKit draws around it is empty.
        let rep = try #require(pill.bitmapImageRepForCachingDisplay(in: pill.bounds))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        pill.drawFocusRingMask()
        NSGraphicsContext.restoreGraphicsState()
        let center = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        #expect(center.alphaComponent > 0.9)
    }

    @Test("Space starts recording a focused pill and a letter doesn't; the recording keeps focus")
    func spaceStartsRecording() async throws {
        let fixture = try await fixture()
        #expect(fixture.window.makeFirstResponder(fixture.first))

        try key(0, "a", in: fixture.window)
        #expect(!fixture.first.isRecording)

        try space(in: fixture.window)
        #expect(fixture.first.isRecording)

        try key(40, "k", .command, in: fixture.window)
        #expect(fixture.records.values == [CommandShortcut(key: "k", modifiers: [.command])])
        #expect(!fixture.first.isRecording)
        #expect(fixture.window.firstResponder === fixture.first)
    }

    @Test("Return and keypad Enter start recording too, and ⌘Return doesn't")
    func returnStartsRecording() async throws {
        let fixture = try await fixture()
        #expect(fixture.window.makeFirstResponder(fixture.first))

        try key(36, "\r", .command, in: fixture.window)
        #expect(!fixture.first.isRecording)

        try key(36, "\r", in: fixture.window)
        #expect(fixture.first.isRecording)

        try key(53, "\u{1b}", in: fixture.window)
        #expect(!fixture.first.isRecording)
        #expect(fixture.window.firstResponder === fixture.first)

        try key(76, "\u{3}", in: fixture.window)
        #expect(fixture.first.isRecording)
        #expect(fixture.records.values.isEmpty)
    }

    @Test("Tab while recording stops without recording and moves on; ⇧Tab moves back")
    func tabLeavesARecording() async throws {
        let fixture = try await fixture()
        #expect(fixture.window.makeFirstResponder(fixture.first))
        try space(in: fixture.window)
        #expect(fixture.first.isRecording)

        try tab(in: fixture.window)
        #expect(!fixture.first.isRecording)
        #expect(fixture.window.firstResponder === fixture.second)

        try space(in: fixture.window)
        #expect(fixture.second.isRecording)
        try tab(backward: true, in: fixture.window)
        #expect(!fixture.second.isRecording)
        #expect(fixture.window.firstResponder === fixture.first)
        #expect(fixture.records.values.isEmpty)
    }

    @Test("a click records and keeps focus; Delete clears and keeps it too")
    func clickRecordsAndKeepsFocus() async throws {
        let fixture = try await fixture()
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        fixture.second.mouseDown(with: click)
        #expect(fixture.second.isRecording)
        #expect(fixture.window.firstResponder === fixture.second)

        try key(51, "\u{7f}", in: fixture.window)
        #expect(fixture.records.values == [nil])
        #expect(!fixture.second.isRecording)
        #expect(fixture.window.firstResponder === fixture.second)
    }

    @Test(
        "Escape is the pill's only while it records; a focused idle pill leaves it to close Settings"
    )
    func escapeBelongsToARecording() async throws {
        let fixture = try await fixture()
        #expect(fixture.window.makeFirstResponder(fixture.first))
        #expect(!EscapeToCloseMonitor.leavesEscape(to: fixture.first))

        try space(in: fixture.window)
        #expect(EscapeToCloseMonitor.leavesEscape(to: fixture.first))

        // Responders that own nothing. Text fields have their own suite (`SettingsEscapeTests`).
        #expect(!EscapeToCloseMonitor.leavesEscape(to: NSView()))
        #expect(!EscapeToCloseMonitor.leavesEscape(to: nil))
    }

    @Test("on the real Shortcuts tab, Tab from Filter reaches a pill")
    func realTabReachesAPill() async throws {
        let store = KeyBindingStore(defaults: ScratchDefaults.fresh())
        let window = window(showing: ShortcutsSettingsView(store: store))
        let field = try #require(try await built(in: window) {
            views(NSTextField.self, in: window).first(where: \.isEditable)
        })
        _ = try #require(try await built(in: window) {
            views(ShortcutRecorder.RecorderView.self, in: window).first
        })
        window.recalculateKeyViewLoop()
        window.selectKeyView(following: field)
        #expect(window.firstResponder is ShortcutRecorder.RecorderView)
    }
}
