import Foundation

/// Which of a strip's tabs get a chip when they do not all fit, and the rest go to an overflow menu.
///
/// Each chip has a narrowest readable width, and the strip shows a **run** of adjacent tabs that fit
/// at those widths rather than any subset. A run keeps every gap between two chips a real slot
/// (``TabSlot``): the gap after the last chip on the strip is the gap before the first tab hidden
/// past it, so a drop lands where the marker says. A subset with a gap in it would make that gap
/// stand for two places at once.
///
/// The showing tab is always in the run, and the run only moves when the showing tab leaves it,
/// by the least that brings it back. Switching between tabs already on the strip moves nothing,
/// so chips do not jump under the pointer.
public enum TabOverflow {
    /// What a strip has to fit.
    public struct Strip: Equatable, Sendable {
        /// Each tab's narrowest chip, in strip order.
        public var minimumWidths: [Double]
        /// The gap between two chips, and between the last chip and the overflow control.
        public var spacing: Double
        /// The width the chips and the overflow control share.
        public var width: Double
        /// The overflow control's own width, spent only once something is hidden.
        public var overflowControlWidth: Double

        public init(
            minimumWidths: [Double],
            spacing: Double,
            width: Double,
            overflowControlWidth: Double
        ) {
            self.minimumWidths = minimumWidths
            self.spacing = spacing
            self.width = width
            self.overflowControlWidth = overflowControlWidth
        }

        /// The width the chips in `range` take at their narrowest, gaps between them included.
        func width(of range: Range<Int>) -> Double {
            minimumWidths[range].reduce(0, +) + Double(max(range.count - 1, 0)) * spacing
        }
    }

    /// The tabs drawn as chips: every one when they all fit, otherwise a run holding `activeIndex`.
    ///
    /// `previousStart` is the first tab of the run shown before, so the run stays where it was
    /// while the showing tab is still in it. When the showing tab is past its end, the run slides
    /// so the showing tab is its last chip; before its start, so it is its first. A run that
    /// reaches the last tab with room to spare takes earlier tabs back rather than leave a gap.
    /// The showing tab gets a chip even when it alone does not fit.
    public static func visibleRange(in strip: Strip, activeIndex: Int, previousStart: Int) -> Range<
        Int
    > {
        let count = strip.minimumWidths.count
        guard count > 0 else { return 0..<0 }
        if strip.width(of: 0..<count) <= strip.width { return 0..<count }

        let room = strip.width - strip.overflowControlWidth - strip.spacing
        let active = min(max(activeIndex, 0), count - 1)
        var start = min(max(previousStart, 0), active)
        var end = start
        while end < count, strip.width(of: start..<end + 1) <= room {
            end += 1
        }
        let slid = active >= end
        if slid {
            start = active
            end = active + 1
        }
        // Growing the run at its front shifts every chip on the strip, so only a run that moved
        // anyway, or one that would otherwise leave room empty after the last tab, does it. A wide
        // tab can stop it early, and then the room left goes to the tabs after the showing one.
        if slid || end == count {
            while start > 0, strip.width(of: start - 1..<end) <= room {
                start -= 1
            }
            while end < count, strip.width(of: start..<end + 1) <= room {
                end += 1
            }
        }
        return start..<end
    }
}
