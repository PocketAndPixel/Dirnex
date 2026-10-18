import AppKit
import Testing

@testable import Dirnex

/// The × after the file name in a Quick View header (2026-10-18), which closes the preview for a
/// hand on the trackpad: every other way out is a key.
@MainActor
@Suite("Quick View ▸ the header's Close button")
struct QuickViewCloseButtonTests {
    @Test("it sits right after the name, and a click runs the surface's close")
    func sitsAfterTheNameAndCloses() throws {
        let hosted = try Self.hosted(header: .pinned)
        var closes = 0
        hosted.preview.onClose = { closes += 1 }
        let caption = QuickViewCaption(name: "notes.txt", position: 1, count: 3)
        hosted.preview.setCaption(caption)
        hosted.window.contentView?.layoutSubtreeIfNeeded()

        let header = try Self.header(of: hosted.preview)
        let name = Self.laidOut(try Self.label(in: header, reading: caption.name))
        let button = Self.laidOut(header.closeButton)
        // Within a point, as layout rounds each frame to the backing pixel on its own.
        #expect(abs(button.minX - (name.maxX + 2)) <= 1)
        #expect(abs(button.midY - name.midY) <= 1)

        header.closeButton.performClick(nil)
        #expect(closes == 1)
    }

    /// The narrowness control for the layout above: a name that cannot fit gives way, and neither
    /// the button nor the position readout is what gets squeezed.
    @Test("a long name truncates before the button reaches the position readout")
    func longNameGivesWay() throws {
        let hosted = try Self.hosted(header: .pinned)
        let caption = QuickViewCaption(
            name: String(repeating: "a very long file name ", count: 12) + ".txt",
            position: 12,
            count: 345
        )
        hosted.preview.setCaption(caption)
        hosted.window.contentView?.layoutSubtreeIfNeeded()

        let header = try Self.header(of: hosted.preview)
        let position = Self.laidOut(try Self.label(in: header, reading: caption.positionText))
        let button = Self.laidOut(header.closeButton)
        #expect(button.width == 20)
        #expect(button.maxX <= position.minX - 12)
        #expect(position.maxX == header.bounds.maxX - 12)
    }

    /// In ⌃Q the surface sits in the *covered* pane, which does not own the mode, so the button has
    /// to reach the window through the pane's host.
    @Test("in the pane-size surface it asks the host to close Quick View")
    func paneSurfaceAsksTheHost() throws {
        let hosted = windowedPane()
        let caption = QuickViewCaption(name: "notes.txt", position: 1, count: 3)
        hosted.pane.showQuickViewPreview(of: nil, style: .default, caption: caption)
        hosted.pane.view.layoutSubtreeIfNeeded()

        let preview = try #require(hosted.pane.quickViewPreview)
        try Self.header(of: preview).closeButton.performClick(nil)
        #expect(hosted.host.quickViewCloses == 1)
    }

    /// A view at zero alpha is still hit-tested, so a faded full-screen header would otherwise close
    /// the preview from a click on a strip of photograph with nothing drawn on it. The pinned header
    /// is the control: same point, same surface, and the button takes it.
    @Test("a faded floating header keeps the button out of reach, a shown one does not")
    func fadedHeaderRefusesTheClick() throws {
        let floating = try Self.hosted(header: .floating)
        floating.preview.setCaption(QuickViewCaption(name: "photo.jpg", position: 1, count: 1))
        floating.window.contentView?.layoutSubtreeIfNeeded()
        let header = try Self.header(of: floating.preview)
        let button = header.closeButton
        let point = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: floating.preview.superview
        )

        #expect(header.alphaValue == 0, "a floating header starts faded out")
        #expect(floating.preview.hitTest(point) === header)
        header.alphaValue = 1
        #expect(floating.preview.hitTest(point) === button)

        let pinned = try Self.hosted(header: .pinned)
        pinned.preview.setCaption(QuickViewCaption(name: "photo.jpg", position: 1, count: 1))
        pinned.window.contentView?.layoutSubtreeIfNeeded()
        let pinnedButton = try Self.header(of: pinned.preview).closeButton
        let pinnedPoint = pinnedButton.convert(
            NSPoint(x: pinnedButton.bounds.midX, y: pinnedButton.bounds.midY),
            to: pinned.preview.superview
        )
        #expect(pinned.preview.hitTest(pinnedPoint) === pinnedButton)
    }

    @Test("the button never takes focus from the file list")
    func refusesFocus() throws {
        let hosted = try Self.hosted(header: .pinned)
        #expect(try Self.header(of: hosted.preview).closeButton.refusesFirstResponder)
    }

    // MARK: - Helpers

    /// An empty surface filling a 400 pt window, which is returned beside it so it lives as long as
    /// the test does.
    static func hosted(
        header: QuickViewPreviewView.Header
    ) throws -> (preview: QuickViewPreviewView, window: NSWindow) {
        let preview = QuickViewPreviewView(
            backingColor: .black,
            header: header,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let content = try #require(window.contentView)
        content.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        return (preview, window)
    }

    static func header(of preview: QuickViewPreviewView) throws -> QuickViewHeaderView {
        try #require(preview.subviews.lazy.compactMap { $0 as? QuickViewHeaderView }.first)
    }

    /// Where layout put `view`, as the constraints see it. A label's frame runs 2 pt wider than that
    /// on each side and a symbol button's taller, so frames would measure the padding instead.
    static func laidOut(_ view: NSView) -> NSRect {
        view.alignmentRect(forFrame: view.frame)
    }

    static func label(in header: QuickViewHeaderView, reading text: String) throws -> NSTextField {
        try #require(
            header.subviews.lazy.compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
        )
    }
}
