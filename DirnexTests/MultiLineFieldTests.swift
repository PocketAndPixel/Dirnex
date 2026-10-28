import AppKit
import Testing

@testable import Dirnex

/// `MultiLineField`, the multi-line text view that looks like a text field (Report a Bug…'s two
/// text boxes, under its email field, its read-only preview, and the scripts organizer's Command).
///
/// The focus ring is the one part not pinned here: a test host's windows are never key, and AppKit
/// draws no ring in a window that isn't, so it is checked in the running app.
/// What a field, or a box, is set to. At file scope so the parameterized `arguments:` can read it:
/// the suite is `@MainActor`, and a type nested in it is main-actor-isolated there.
enum FieldState: CaseIterable, Sendable {
    case editable, readOnly, disabled

    @MainActor
    func apply(to field: NSTextField) {
        field.isEditable = self != .readOnly
        field.isEnabled = self != .disabled
    }

    @MainActor
    func apply(to box: MultiLineField) {
        box.isEditable = self != .readOnly
        box.isEnabled = self != .disabled
    }
}

@Suite("Multi-line field")
@MainActor
struct MultiLineFieldTests {
    private static let size = NSSize(width: 300, height: 96)

    /// A box in a window of its own, laid out at `size`.
    private func box(_ appearance: NSAppearance.Name = .aqua) -> (MultiLineField, NSWindow) {
        let box = MultiLineField(MultiLineTextView())
        let window = host(box, appearance)
        return (box, window)
    }

    private func host(_ view: NSView, _ appearance: NSAppearance.Name) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 340, height: 136)),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let content = NSView()
        window.contentView = content
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            view.widthAnchor.constraint(equalToConstant: Self.size.width),
            view.heightAnchor.constraint(equalToConstant: Self.size.height)
        ])
        content.layoutSubtreeIfNeeded()
        return window
    }

    private func bezel(of box: MultiLineField) throws -> NSTextField {
        try #require(box.subviews.lazy.compactMap { $0 as? NSTextField }.first)
    }

    /// How many pixels of `view` differ from `reference`'s, which has to have drawn something.
    private func differingPixels(_ view: NSView, from reference: NSView) throws -> Int {
        let drawnPixels = try BitmapPixels(capturing: view)
        let expectedPixels = try BitmapPixels(capturing: reference)
        try #require(drawnPixels.width == expectedPixels.width)
        try #require(drawnPixels.height == expectedPixels.height)
        try #require(drawnPixels.colorSpace == expectedPixels.colorSpace)
        var differing = 0
        var inked = 0
        for y in 0..<expectedPixels.height {
            for x in 0..<expectedPixels.width {
                let drawn = drawnPixels.rgba(x: x, y: y)
                let expected = expectedPixels.rgba(x: x, y: y)
                let delta = abs(drawn.x - expected.x) + abs(drawn.y - expected.y)
                    + abs(drawn.z - expected.z) + abs(drawn.w - expected.w)
                if delta > 0.02 { differing += 1 }
                if expected.w > 0 { inked += 1 }
            }
        }
        // A field that drew nothing would match a box that drew nothing.
        #expect(inked > expectedPixels.width * expectedPixels.height / 2)
        return differing
    }

    /// The point of the whole view, and the reason the bezel is a real field rather than a drawing
    /// of one: on macOS 26 a field's bezel is a private hosting view's, which no hand-drawn rectangle
    /// matched. A non-editable bezel fails the editable case in Dark Mode, where it draws its border
    /// differently. Read-only, it is Report a Bug…'s preview; disabled, the scripts organizer's
    /// Command with no script selected, beside a disabled Name and Keywords.
    @Test(
        "an empty box draws exactly what a text field of its size draws",
        arguments: [NSAppearance.Name.aqua, .darkAqua], FieldState.allCases
    )
    func looksLikeAField(appearance: NSAppearance.Name, state: FieldState) throws {
        // Each is set before it is on screen: a field on screen animates the change, and a capture
        // taken during it differs (the read-only case did, in Light Mode).
        let box = MultiLineField(MultiLineTextView())
        state.apply(to: box)
        let boxWindow = host(box, appearance)
        let field = NSTextField.singleLine()
        state.apply(to: field)
        let fieldWindow = host(field, appearance)
        let other = NSTextField.singleLine()
        (state == .editable ? FieldState.readOnly : .editable).apply(to: other)
        let otherWindow = host(other, appearance)
        defer {
            boxWindow.close()
            fieldWindow.close()
            otherWindow.close()
        }
        #expect(try differingPixels(box, from: field) == 0)
        // Otherwise the box would pass in this state whatever setting it did.
        #expect(try differingPixels(other, from: field) > 0)
    }

    @Test("a read-only box can be selected in but not typed in, and draws no focus ring")
    func readOnly() {
        let (box, window) = box()
        defer { window.close() }
        let textView = box.textView
        box.isEditable = false
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        #expect(textView.acceptsFirstResponder)
        #expect(box.scrollView.focusRingType == .none)
        // Disabling and enabling again leaves it read-only.
        box.isEnabled = false
        #expect(!textView.isSelectable)
        box.isEnabled = true
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        box.isEditable = true
        #expect(textView.isEditable)
        #expect(box.scrollView.focusRingType == .exterior)
    }

    @Test("a disabled box can't take focus and dims its text, and enabling it brings both back")
    func disabling() {
        let (box, window) = box()
        defer { window.close() }
        let textView = box.textView
        box.isEnabled = false
        #expect(!box.isEnabled)
        #expect(!textView.isEditable)
        #expect(!textView.acceptsFirstResponder)
        #expect(textView.textColor == .disabledControlTextColor)
        box.isEnabled = true
        #expect(textView.isEditable)
        #expect(textView.acceptsFirstResponder)
        textView.insertText("echo hi", replacementRange: NSRange(location: 0, length: 0))
        let typed = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        #expect(typed as? NSColor == .textColor)
    }

    /// The scripts organizer's Command fills what its form leaves over. The field behind the text
    /// hugs its one-line height, and would hold the box to it if it were let.
    @Test("a box a stack view stretches takes the room it is given")
    func stretches() throws {
        let box = MultiLineField(MultiLineTextView())
        box.setContentHuggingPriority(.defaultLow, for: .vertical)
        box.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let label = NSTextField(labelWithString: "Command")
        let stack = NSStackView(views: [label, box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let window = host(stack, .aqua)
        defer { window.close() }
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.layoutSubtreeIfNeeded()
        #expect(box.frame.height == Self.size.height - 6 - label.frame.height)
        #expect(try bezel(of: box).frame == box.bounds)
    }

    @Test("the bezel is off the Tab loop")
    func bezelIsOffTheTabLoop() throws {
        let (box, window) = box()
        defer { window.close() }
        let bezel = try bezel(of: box)
        #expect(!bezel.acceptsFirstResponder)
        #expect(!bezel.canBecomeKeyView)
        #expect(box.textView.acceptsFirstResponder)
    }

    /// The roles of every element VoiceOver reaches from `element` down.
    private func roles(under element: Any) -> [NSAccessibility.Role] {
        guard let element = element as? NSAccessibilityProtocol else { return [] }
        let children = NSAccessibility.unignoredChildren(from: element.accessibilityChildren() ?? [])
        return children.flatMap { child in
            ((child as? NSAccessibilityProtocol)?.accessibilityRole().map { [$0] } ?? [])
                + roles(under: child)
        }
    }

    /// Hiding the bezel itself is not enough, and is what this was first written as: measured in the
    /// running app, `setAccessibilityElement(false)` on the field left an empty `AXTextField` the
    /// size of the box in the tree, its private hosting view promoted into its place. This test
    /// failed the same way against that version.
    @Test("VoiceOver finds one text area in the box and no text field")
    func bezelIsHiddenFromVoiceOver() throws {
        let (box, window) = box()
        defer { window.close() }
        let roles = roles(under: try #require(window.contentView))
        #expect(roles.count(where: { $0 == .textArea }) == 1)
        #expect(!roles.contains(.textField))
    }

    /// What VoiceOver finds under the pointer, on the bezel's margin and over the text alike.
    @Test("pointing anywhere in the box finds the text, never the bezel")
    func hitTestingFindsTheText() throws {
        let (box, window) = box()
        defer { window.close() }
        let frame = box.frame
        let points = [
            NSPoint(x: frame.minX + MultiLineField.textInset.width / 2, y: frame.midY),
            NSPoint(x: frame.midX, y: frame.maxY - MultiLineField.textInset.height / 2),
            NSPoint(x: frame.midX, y: frame.midY)
        ]
        for point in points {
            let onScreen = window.convertPoint(toScreen: point)
            let found = window.accessibilityHitTest(onScreen) as? NSAccessibilityProtocol
            #expect(found?.accessibilityRole() == .textArea)
        }
    }

    @Test("a click on the bezel's margin goes to the text")
    func marginClickReachesTheText() throws {
        let (box, window) = box()
        defer { window.close() }
        let frame = box.frame
        let inset = MultiLineField.textInset
        let margins = [
            NSPoint(x: frame.minX + inset.width / 2, y: frame.midY),
            NSPoint(x: frame.maxX - inset.width / 2, y: frame.midY),
            NSPoint(x: frame.midX, y: frame.minY + inset.height / 2),
            NSPoint(x: frame.midX, y: frame.maxY - inset.height / 2)
        ]
        for point in margins {
            #expect(box.hitTest(point) === box.textView)
        }
        #expect(box.hitTest(NSPoint(x: frame.minX - 1, y: frame.midY)) == nil)
    }

    /// A window that has only been ordered front isn't key, so its first press takes the path a click
    /// from another app takes (only the first: `BugReportDialogFocusTests` says why). The window hands
    /// it on only to a view that accepts first mouse (docs/NOTES.md ▸ Testing). Negative control: with
    /// `MultiLineTextView` answering `false`, the focus stays where it was.
    @Test("one click from another app puts the focus in the box")
    func clickFromAnotherApp() throws {
        let (box, window) = box()
        window.orderFront(nil)
        defer {
            window.close()
            NSApp.discardEvents(matching: .leftMouseUp, before: nil)
        }
        try #require(!window.isKeyWindow)
        // Ordering the window front makes the box, its one key view, the first responder.
        window.makeFirstResponder(nil)
        try #require(window.firstResponder === window)
        try Self.click(box, in: window)
        #expect(window.firstResponder === box.textView)
    }

    /// A press at the middle of `view`, or of the scroll view it sits in, sent the way a window gets
    /// one, with the release queued for the tracking loop the press starts. A press the window keeps
    /// for itself leaves its release queued, so a caller discards what is left.
    static func click(_ view: NSView, in window: NSWindow) throws {
        let target = view.enclosingScrollView ?? view
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let press = try QuickViewHeaderStyleTests.mouseEvent(.leftMouseDown, at: point, in: window)
        let release = try QuickViewHeaderStyleTests.mouseEvent(.leftMouseUp, at: point, in: window)
        NSApp.postEvent(release, atStart: true)
        window.sendEvent(press)
    }

    /// The text view itself is never asked for a ring inside a scroll view, so the scroll view has
    /// to want one, and it has to go around the bezel rather than the narrower scroll view.
    @Test("the scroll view asks for the focus ring, around the whole bezel")
    func focusRingSurroundsTheBezel() throws {
        let (box, window) = box()
        defer { window.close() }
        let scrollView = box.scrollView
        #expect(scrollView.focusRingType == .exterior)
        #expect(scrollView.documentView === box.textView)
        #expect(scrollView.convert(scrollView.focusRingMaskBounds, to: box) == box.bounds)
        #expect(scrollView.frame == box.bounds.insetBy(
            dx: MultiLineField.textInset.width,
            dy: MultiLineField.textInset.height
        ))
    }
}
