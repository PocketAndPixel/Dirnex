import AppKit
import Testing

@testable import Dirnex

/// The focus ring Dirnex draws for a color well that Tab reached with the system's Keyboard
/// navigation switch off.
///
/// The test host's windows are never key and the switch is whatever this Mac has, so both are set
/// through ``ColorWellFocusRing``'s seams and put back afterwards — which is also why the suite is
/// serialized. The observable is the ring's `isHidden`, read after focus moves through the real
/// `makeFirstResponder`, so the wrapped `becomeFirstResponder` and the first-responder observation
/// are both on the path under test.
@Suite("Color well focus ring", .serialized)
@MainActor
struct ColorWellFocusRingTests {
    private struct Fixture {
        let window: NSWindow
        let field: NSTextField
        let well: NSColorWell
        let other: NSColorWell
    }

    private func fixture() -> Fixture {
        KeyboardReachableControls.install()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let field = NSTextField(string: "name")
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 48, height: 24))
        let other = NSColorWell(frame: NSRect(x: 0, y: 0, width: 48, height: 24))
        let stack = NSStackView(views: [field, well, other])
        stack.orientation = .vertical
        window.contentView = stack
        window.layoutIfNeeded()
        return Fixture(window: window, field: field, well: well, other: other)
    }

    /// Run `body` with the window reported key (or not) and the system switch reported off (or on).
    private func with(key: Bool, systemRings: Bool = false, _ body: () throws -> Void) rethrows {
        let savedKey = ColorWellFocusRing.windowIsKey
        let savedRings = ColorWellFocusRing.systemDrawsRings
        defer {
            ColorWellFocusRing.windowIsKey = savedKey
            ColorWellFocusRing.systemDrawsRings = savedRings
        }
        ColorWellFocusRing.windowIsKey = { _ in key }
        ColorWellFocusRing.systemDrawsRings = { systemRings }
        try body()
    }

    @Test("a focused well shows its ring, and loses it when focus moves on")
    func ringFollowsFocus() throws {
        let fixture = fixture()
        try with(key: true) {
            #expect(fixture.window.makeFirstResponder(fixture.well))
            let ring = try #require(ColorWellFocusRing.ring(of: fixture.well))
            #expect(!ring.isHidden)

            #expect(fixture.window.makeFirstResponder(fixture.other))
            #expect(ring.isHidden)
            #expect(ColorWellFocusRing.ring(of: fixture.other)?.isHidden == false)

            #expect(fixture.window.makeFirstResponder(fixture.field))
            #expect(ColorWellFocusRing.ring(of: fixture.other)?.isHidden == true)

            #expect(fixture.window.makeFirstResponder(fixture.well))
            #expect(!ring.isHidden)
            #expect(fixture.well.subviews.count { $0 is ColorWellFocusRing } == 1)
        }
    }

    @Test("the ring waits for its window to become key, and ignores other windows doing so")
    func ringFollowsKeyWindow() throws {
        let fixture = fixture()
        try with(key: false) {
            #expect(fixture.window.makeFirstResponder(fixture.well))
            let ring = try #require(ColorWellFocusRing.ring(of: fixture.well))
            #expect(ring.isHidden)

            ColorWellFocusRing.windowIsKey = { _ in true }
            let stranger = NSWindow()
            NotificationCenter.default.post(
                name: NSWindow.didBecomeKeyNotification,
                object: stranger
            )
            #expect(ring.isHidden)

            NotificationCenter.default.post(
                name: NSWindow.didBecomeKeyNotification,
                object: fixture.window
            )
            #expect(!ring.isHidden)

            ColorWellFocusRing.windowIsKey = { _ in false }
            NotificationCenter.default.post(
                name: NSWindow.didResignKeyNotification,
                object: fixture.window
            )
            #expect(ring.isHidden)
        }
    }

    @Test("no ring shows while the system's Keyboard navigation switch is on")
    func systemSwitchWins() throws {
        let fixture = fixture()
        try with(key: true, systemRings: true) {
            #expect(fixture.window.makeFirstResponder(fixture.well))
            let ring = ColorWellFocusRing.ring(of: fixture.well)
            #expect(ring == nil || ring?.isHidden == true)
        }
    }

    @Test("a well taken out of its window hides its ring, and does not bring it back unfocused")
    func removalHidesRing() throws {
        let fixture = fixture()
        try with(key: true) {
            #expect(fixture.window.makeFirstResponder(fixture.well))
            let ring = try #require(ColorWellFocusRing.ring(of: fixture.well))
            let stack = try #require(fixture.well.superview as? NSStackView)
            fixture.well.removeFromSuperview()
            #expect(ring.isHidden)
            stack.addArrangedSubview(fixture.well)
            #expect(ring.isHidden)
        }
    }

    @Test("the ring sits just outside the well and lets clicks through to it")
    func ringGeometryAndClicks() throws {
        let fixture = fixture()
        try with(key: true) {
            #expect(fixture.window.makeFirstResponder(fixture.well))
            let ring = try #require(ColorWellFocusRing.ring(of: fixture.well))
            let outset = ColorWellFocusRing.outset
            #expect(ring.frame == fixture.well.bounds.insetBy(dx: -outset, dy: -outset))
            #expect(ring.hitTest(NSPoint(x: ring.bounds.midX, y: ring.bounds.midY)) == nil)
        }
    }
}
