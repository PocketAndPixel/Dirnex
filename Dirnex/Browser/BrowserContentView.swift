import AppKit

/// The browser window's content view. It hands a double-click nothing under it wanted to the window's
/// frame view, so the free space in the title bar's row does what free space in any title bar does.
///
/// The tab strips and the sidebar run under the transparent title bar and take its clicks
/// (docs/NOTES.md ▸ Windows). A click they leave alone climbs the responder chain to here and stops:
/// a content view's next responder is the window, which skips the frame view around it. That frame
/// view is where AppKit keeps the whole behaviour, on mouse-up: only inside the title bar's rect, and
/// whichever of zoom, fill, minimize or nothing System Settings asks for. So it gets the event, and
/// none of that is repeated here.
@MainActor
final class BrowserContentView: NSView {
    /// Set by a chip's ×. The chip is gone by the next click, and if it was the strip's last that
    /// click lands on the free space it left, so the pair would read as a double-click on the title
    /// bar and a quick second press on a × would zoom the window.
    var ignoresNextDoubleClick = false

    override func mouseUp(with event: NSEvent) {
        let ignored = ignoresNextDoubleClick
        ignoresNextDoubleClick = false
        // A window in full screen has no title bar here and nothing to zoom to.
        guard event.clickCount == 2, !ignored, let frameView = superview,
              window?.styleMask.contains(.fullScreen) == false
        else {
            super.mouseUp(with: event)
            return
        }
        frameView.mouseUp(with: event)
    }
}
