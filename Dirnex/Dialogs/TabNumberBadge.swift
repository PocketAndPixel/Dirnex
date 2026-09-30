import AppKit

/// The small numbered capsule ``TabShortcuts`` puts on a tab while ⌘ is held.
///
/// It straddles the tab's top-trailing corner, like a notification badge, so it covers neither the
/// label nor the tab next to it. It is drawn in the label colour with the window's background colour
/// for the digit — white on dark and black on light — so it stays legible over both the accent-filled
/// selected tab and the grey ones, and it resolves its colours when it draws, following the
/// appearance live. Clicks go to the tab underneath.
final class TabNumberBadge: NSView {
    static let size = NSSize(width: 16, height: 15)

    let number: Int

    init(number: Int) {
        self.number = number
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let text = NSAttributedString(
            string: String(number),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.windowBackgroundColor
            ]
        )
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    /// Where the badge goes for a tab occupying `tab` inside `container`: its centre a few points
    /// inside the tab's trailing edge, level with the tab's top edge — moved down only as far as it
    /// takes to stay inside `container`.
    ///
    /// The clamp is measured, not tidiness, and ``room(in:)`` is what it clamps to.
    static func frame(forTab tab: NSRect, in container: NSRect, flipped: Bool) -> NSRect {
        var frame = NSRect(
            x: tab.maxX - 5 - size.width / 2,
            y: (flipped ? tab.minY : tab.maxY) - size.height / 2,
            width: size.width,
            height: size.height
        )
        if flipped {
            frame.origin.y = max(frame.minY, container.minY)
        } else {
            frame.origin.y = min(frame.minY, container.maxY - size.height)
        }
        return frame
    }

    /// Where a badge on `tabs` can be seen: inside the tab view, and below the window's title bar.
    ///
    /// In Settings SwiftUI places the tab view 6 pt above the content area, so the tab bar sits right
    /// under the title bar, and a badge straddling a tab's top edge was drawn where the title bar
    /// paints over the content — measured, badges at y −2.5 against a content area starting at 6,
    /// with only their lower halves showing. Neither the tab view's bounds nor its `visibleRect` can
    /// say so (the window's frame is what clips, and the title bar is inside it), while
    /// `contentLayoutRect` is exactly the part of the window the title bar leaves alone.
    @MainActor
    static func room(in tabs: NSView) -> NSRect {
        guard let window = tabs.window else { return tabs.visibleRect }
        return tabs.visibleRect.intersection(tabs.convert(window.contentLayoutRect, from: nil))
    }

    /// Each tab's rectangle in `tabs`' coordinates, in tab order.
    ///
    /// The tabs are drawn by a private segmented control whose segment rectangles are not public API,
    /// but accessibility publishes them: the control's cell answers one element per segment with its
    /// screen frame (probed 2026-09-13 — General at x 0, Permissions at 72, and so on). An answer that
    /// does not account for every tab comes back empty, so a changed layout shows no numbers rather
    /// than wrong ones.
    @MainActor
    static func tabRects(in tabs: NSTabView) -> [NSRect] {
        guard let window = tabs.window,
              let control = tabs.subviews.lazy.compactMap({ $0 as? NSSegmentedControl }).first,
              let cell = control.accessibilityChildren()?.lazy.compactMap({ $0 as? NSCell }).first
        else { return [] }
        let frameSelector = NSSelectorFromString("accessibilityFrame")
        let frames = (cell.accessibilityChildren() ?? []).compactMap { segment -> NSRect? in
            // The segments are a private element class, so they are read as plain objects rather than
            // through a protocol they are not declared to adopt.
            guard let segment = segment as? NSObject, segment.responds(to: frameSelector) else { return nil }
            return segment.value(forKey: "accessibilityFrame") as? NSRect
        }
        return frames.map { tabs.convert(window.convertFromScreen($0), from: nil) }
    }
}
