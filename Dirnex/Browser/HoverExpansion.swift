import AppKit

/// Resting the pointer on a value its column cuts short floats it whole, in `ExpansionPanel`. This is
/// what AppKit's expansion tooltip used to do, until its panel turned out to look different from the
/// ⌘ hold's (`ExpansionPanel` has the measurement).
///
/// It keeps AppKit's timing and manners: ``delay`` is AppKit's own, measured; the panel goes when the
/// pointer leaves the value; and a click, a key or a scroll takes it away and keeps it away until the
/// pointer moves again.
///
/// **Driven by a local monitor on mouse-moved events**, which a pane's window already posts for the
/// table's own hover (`FileTableView` turns `acceptsMouseMovedEvents` on), so nothing here needs a
/// tracking area. **While the panel is up, a short poll watches the pointer instead**, because the
/// ways it goes stale send no event here: the pointer leaving the window, or the rows scrolling or
/// reloading under a pointer that has not moved.
@MainActor
enum HoverExpansion {
    /// How long the pointer rests on a truncated value before it floats. AppKit's own, measured
    /// 2026-10-15 from the last mouse-moved event to its panel being drawn: 1.508 s and 1.501 s.
    static let delay: TimeInterval = 1.5

    /// How often the pointer is checked while the panel is up.
    static let watchInterval: TimeInterval = 0.1

    private static var monitors: [Any] = []
    private static var revealTimer: Timer?
    private static var watchTimer: Timer?
    /// The value a reveal is waiting on, so that moving within it does not restart the wait.
    private static var pending: ExpansionPanel.Key?

    /// Install once, when the app starts. Later calls do nothing.
    static func install() {
        guard monitors.isEmpty else { return }
        if let moves = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            MainActor.assumeIsolated { pointerMoved(in: event.window) }
            return event
        }) {
            monitors.append(moves)
        }
        let interruptions: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        if let other = NSEvent.addLocalMonitorForEvents(matching: interruptions, handler: { event in
            MainActor.assumeIsolated { cancel() }
            return event
        }) {
            monitors.append(other)
        }
    }

    /// The file cell's label under `screenPoint` in `window`, when its column cuts its value short.
    /// `nil` over anything else, including a value that fits.
    static func truncatedLabel(at screenPoint: NSPoint, in window: NSWindow) -> NSTextField? {
        guard let frameView = window.contentView?.superview else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        var view = frameView.hitTest(frameView.convert(windowPoint, from: nil))
        while let current = view {
            if let cell = current as? NSTableCellView {
                guard let label = cell.textField, label is ExpandingLabel,
                      label.bounds.contains(label.convert(windowPoint, from: nil)),
                      ExpansionPanel.screenFrame(for: label) != nil else { return nil }
                return label
            }
            view = current.superview
        }
        return nil
    }

    /// Take the hover's panel away and forget a reveal that has not happened yet. A ⌘ hold's panel is
    /// left alone.
    static func cancel() {
        revealTimer?.invalidate()
        revealTimer = nil
        pending = nil
        watchTimer?.invalidate()
        watchTimer = nil
        ExpansionPanel.hide(ifShownBy: .hover)
    }

    // MARK: - Monitors

    private static func pointerMoved(in window: NSWindow?) {
        guard let window, window.isKeyWindow,
              let label = truncatedLabel(at: NSEvent.mouseLocation, in: window) else {
            cancel()
            return
        }
        let key = ExpansionPanel.key(for: label)
        if key == pending { return }
        if ExpansionPanel.owner == .hover, ExpansionPanel.isShowing(label) { return }
        cancel()
        pending = key
        let timer = Timer(timeInterval: delay, repeats: false) { [weak window] _ in
            MainActor.assumeIsolated {
                revealTimer = nil
                pending = nil
                // Asked again rather than trusted: a reload or a key may have moved the rows.
                guard let window, window.isKeyWindow,
                      let label = truncatedLabel(at: NSEvent.mouseLocation, in: window),
                      ExpansionPanel.show(over: label, for: .hover) else { return }
                watchPointer(in: window)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    /// Keep the panel only while the pointer is still on the value it shows.
    private static func watchPointer(in window: NSWindow) {
        let timer = Timer(timeInterval: watchInterval, repeats: true) { [weak window] _ in
            MainActor.assumeIsolated {
                // A ⌘ hold took the panel over, or something took it down: nothing left to watch.
                guard ExpansionPanel.owner == .hover else {
                    watchTimer?.invalidate()
                    watchTimer = nil
                    return
                }
                guard let window, NSApp.isActive, window.isKeyWindow,
                      let label = truncatedLabel(at: NSEvent.mouseLocation, in: window),
                      ExpansionPanel.isShowing(label) else {
                    cancel()
                    return
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }
}
