import Foundation

/// How far a pane's tab strip stays in from each of its ends, clear of the title bar's own controls.
///
/// The strips run in the window's title bar row, and the window's controls sit on top of them: the
/// traffic lights and the sidebar toggle from the left edge, the license label and the update
/// indicator from the right. A chip under one of those can be seen but not clicked.
///
/// A control is placed from the window's edge and a strip from wherever its pane has got to, so this
/// is worked out from the strip's own position rather than from which pane it belongs to. With the
/// sidebar open the left strip starts past every control and needs nothing, with it closed it starts
/// under them, and half way through the sidebar's animation it needs the part still covered.
public struct TitlebarClearance: Equatable, Sendable {
    /// How far the title bar's controls reach in from each edge of the window.
    public struct Controls: Equatable, Sendable {
        public var fromLeft: Double
        public var fromRight: Double

        public init(fromLeft: Double, fromRight: Double) {
            self.fromLeft = fromLeft
            self.fromRight = fromRight
        }

        /// No controls to clear: in full screen the title bar is a window of its own, which comes
        /// down over the strips only while the pointer is at the top of the screen.
        public static let none = Controls(fromLeft: 0, fromRight: 0)
    }

    /// How far the chips start in from the strip's left end.
    public var leading: Double
    /// How far the strip's contents stop short of its right end.
    public var trailing: Double

    public static let none = TitlebarClearance(leading: 0, trailing: 0)

    public init(leading: Double, trailing: Double) {
        self.leading = leading
        self.trailing = trailing
    }

    /// The clearance for a strip spanning `stripMinX`…`stripMaxX` in a window `windowWidth` wide, all
    /// in window coordinates.
    public init(stripMinX: Double, stripMaxX: Double, windowWidth: Double, controls: Controls) {
        leading = max(controls.fromLeft - stripMinX, 0)
        trailing = max(stripMaxX - (windowWidth - controls.fromRight), 0)
    }
}
