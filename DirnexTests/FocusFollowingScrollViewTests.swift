import AppKit
import Testing

@testable import Dirnex

/// Tab onto a control below a scrolling pane's fold scrolls the pane to it.
///
/// Built through ``AttributeRow/pane(_:width:)`` — the funnel every Get Info tab uses — in a window
/// too short for its rows, and driven by the real `makeFirstResponder`, so the first-responder
/// observation is on the path under test. The observable is the clip view's visible rectangle
/// against the focused control's frame, which needs no key window and no screenshot.
@Suite("Focus-following scroll view")
@MainActor
struct FocusFollowingScrollViewTests {
    private struct Fixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let boxes: [NSButton]
        let field: NSTextField
        let outside: NSButton
    }

    /// Forty checkboxes and a text field in a pane 120 pt tall, and a button beside the pane.
    private func fixture() throws -> Fixture {
        KeyboardReachableControls.install()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let boxes = (0..<40).map { NSButton(checkboxWithTitle: "Box \($0)", target: nil, action: nil) }
        let field = NSTextField(string: "last")
        field.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let scrollView = try #require(
            AttributeRow.pane(boxes + [field], width: 300) as? NSScrollView
        )
        let outside = NSButton(title: "Outside", target: nil, action: nil)
        let stack = NSStackView(views: [scrollView, outside])
        stack.orientation = .vertical
        scrollView.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scrollView.widthAnchor.constraint(equalToConstant: 320).isActive = true
        window.contentView = stack
        window.layoutIfNeeded()
        return Fixture(
            window: window,
            scrollView: scrollView,
            boxes: boxes,
            field: field,
            outside: outside
        )
    }

    private func isVisible(_ view: NSView, in scrollView: NSScrollView) -> Bool {
        guard let document = scrollView.documentView else { return false }
        let frame = view.convert(view.bounds, to: document)
        return scrollView.contentView.documentVisibleRect.contains(frame)
    }

    @Test("focusing a control below the fold scrolls it into sight, and back up again")
    func focusScrollsBothWays() throws {
        let fixture = try fixture()
        let last = try #require(fixture.boxes.last)
        let first = try #require(fixture.boxes.first)
        #expect(isVisible(first, in: fixture.scrollView))
        #expect(!isVisible(last, in: fixture.scrollView))

        #expect(fixture.window.makeFirstResponder(last))
        #expect(isVisible(last, in: fixture.scrollView))

        #expect(fixture.window.makeFirstResponder(first))
        #expect(isVisible(first, in: fixture.scrollView))
    }

    @Test("a text field below the fold is revealed through its field editor")
    func fieldEditorIsTracedToItsField() throws {
        let fixture = try fixture()
        #expect(!isVisible(fixture.field, in: fixture.scrollView))
        #expect(fixture.window.makeFirstResponder(fixture.field))
        #expect(isVisible(fixture.field, in: fixture.scrollView))
    }

    @Test("focus moving to a control outside the pane leaves the pane where it is")
    func focusOutsideDoesNotScroll() throws {
        let fixture = try fixture()
        let middle = fixture.boxes[20]
        #expect(fixture.window.makeFirstResponder(middle))
        let scrolled = fixture.scrollView.contentView.bounds.origin
        #expect(fixture.window.makeFirstResponder(fixture.outside))
        #expect(fixture.scrollView.contentView.bounds.origin == scrolled)
    }
}
