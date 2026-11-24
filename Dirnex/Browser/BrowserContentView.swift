import AppKit

/// The browser window's content view. It hands a double-click nothing under it wanted to the window's
/// frame view, so the free space in the title bar's row does what free space in any title bar does.
///
/// The tab strips and the sidebar run under the transparent title bar and take its clicks
/// (docs/NOTES.md ▸ Windows). A click they leave alone climbs the responder chain to here and stops:
/// a content view's next responder is the window, which skips the frame view around it. Up to macOS
/// 26 that frame view is where AppKit keeps the whole behaviour, on mouse-up: only inside the title
/// bar's rect, and whichever of zoom, fill, minimize or nothing System Settings asks for. So it gets
/// the event, and none of that is repeated here.
///
/// From macOS 27 the frame view's mouse-up does nothing, and its gesture recognizers act on no press
/// under a transparent title bar, so this does what the setting asks itself
/// (`TitleBarDoubleClickAction`).
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
        guard event.clickCount == 2, !ignored, let window, let frameView = superview,
              !window.styleMask.contains(.fullScreen)
        else {
            super.mouseUp(with: event)
            return
        }
        guard #available(macOS 27, *) else {
            frameView.mouseUp(with: event)
            return
        }
        // As AppKit's own rule had it: inside the title bar's rect, and not a ⌃-click.
        guard event.locationInWindow.y >= window.contentLayoutRect.maxY,
              !event.modifierFlags.contains(.control)
        else {
            super.mouseUp(with: event)
            return
        }
        TitleBarDoubleClickAction.current.perform(on: window)
    }
}

/// What System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to" asks for, read from
/// `AppleActionOnDoubleClick`, the default AppKit reads. On macOS 27.2 AppKit registers `Maximize` for
/// it, so it answers even on a Mac where the setting was never changed.
enum TitleBarDoubleClickAction: Equatable {
    case zoom
    case minimize
    case nothing

    /// `setting` is `Maximize`, `Fill`, `Minimize` or `None`. Fill takes the window to the screen's
    /// visible frame, which is also where zoom takes a window with no maximum size, as the browser
    /// window is (docs/NOTES.md ▸ Windows), and AppKit's own call for it is private. A value this
    /// does not know falls back to the older `AppleMiniaturizeOnDoubleClick`, and then to zoom.
    init(setting: String?, legacyMinimizes: Bool) {
        switch setting {
        case "Maximize", "Fill": self = .zoom
        case "Minimize": self = .minimize
        case "None": self = .nothing
        default: self = legacyMinimizes ? .minimize : .zoom
        }
    }

    static var current: Self {
        let defaults = UserDefaults.standard
        return Self(
            setting: defaults.string(forKey: "AppleActionOnDoubleClick"),
            legacyMinimizes: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")
        )
    }

    /// The same calls the zoom and minimize buttons make.
    @MainActor
    func perform(on window: NSWindow) {
        switch self {
        case .zoom: window.performZoom(nil)
        case .minimize: window.performMiniaturize(nil)
        case .nothing: break
        }
    }
}
