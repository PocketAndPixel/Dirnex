import AppKit

/// The line between Quick View's table and the strip under it, which a drag moves up and down and a
/// double-click puts back (2026-09-15).
///
/// A thin view laid over the strip's top edge rather than an `NSSplitView` around the two: the strip
/// sizes itself to the selected row until somebody drags it, and a split view would own that height
/// from the start. It reports and does nothing else; `QuickViewTableView+StripHeight` decides what a
/// height means.
@MainActor
final class QuickViewStripHandle: NSView {
    /// The strip's height as a drag starts.
    var currentHeight: () -> CGFloat = { 0 }
    /// The height a drag asks for, before any bound.
    var resize: (CGFloat) -> Void = { _ in }
    /// A double-click: back to the height the row needs.
    var fit: () -> Void = {}

    private struct DragStart {
        let pointer: CGFloat
        let height: CGFloat
    }

    private var dragStart: DragStart?

    /// A divider's cursor where the system has one, and the arrows it replaced before that.
    static var cursor: NSCursor {
        if #available(macOS 15, *) { return .rowResize }
        return .resizeUpDown
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A cursor update rather than a cursor rect: the strip's text view sits under this edge with
        // an I-beam of its own, and a cursor update goes to the view the pointer hits, which is this.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.cursor.set()
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Measured in the window's coordinates, where up is always up, so a drag reads the same whether
    /// or not anything between here and the window is flipped.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            dragStart = nil
            fit()
            return
        }
        dragStart = DragStart(pointer: event.locationInWindow.y, height: currentHeight())
        Self.cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        resize(dragStart.height + event.locationInWindow.y - dragStart.pointer)
        // Set on every step, since the pointer runs ahead of the edge it is moving and would take
        // the cursor of whatever it passes over.
        Self.cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}
