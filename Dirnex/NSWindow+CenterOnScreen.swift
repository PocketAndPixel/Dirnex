import AppKit

extension NSWindow {
    /// Positions the window at the true centre of its screen's usable area — the `visibleFrame`,
    /// which excludes the menu bar and the Dock.
    ///
    /// AppKit's own `center()` biases the window *above* the vertical midpoint by design, and it
    /// must be called once the window already has its final size. This helper puts the window
    /// dead-centre instead, and is used for the app's default first-run placement and for the
    /// Settings window so both open centred by default.
    func centerOnScreen() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        ))
    }
}
