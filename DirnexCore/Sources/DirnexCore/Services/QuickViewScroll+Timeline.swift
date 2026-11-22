import Foundation

/// The same ⇧-keys over a movie or a sound in Quick View (PLAN.md §M42 ▸ Slice 1): a player has no
/// document to scroll, so each key moves along the timeline instead, in the direction it moves down a
/// document. ⇧↑ / ⇧↓ go back and forward a line step, ⇧Page Up / ⇧Page Down a page step, and ⇧← / ⇧→
/// go to the start and the end, so every backend reads the same key the same way round.
///
/// Here rather than in the app because it is the whole of the rule, and a player's own seek takes
/// whatever it is handed: what the keys mean is arithmetic, and the clamping is where it goes wrong.
extension QuickViewScroll {
    /// A line step on a timeline, in seconds.
    public static let timelineLineStep: Double = 10

    /// A page step on a timeline, in seconds.
    public static let timelinePageStep: Double = 60

    /// Where this move takes a player standing at `current` seconds into something `duration` seconds
    /// long, held inside the timeline.
    ///
    /// A `duration` that is unknown — `nil`, not finite, or not positive, as a stream's is before its
    /// end has been read — holds only the start: there is no end to go to, so `.end` stays where it
    /// is and a step forward goes as far as it asks. A `current` that is not finite counts as the
    /// start, which is what a player reports before it has a position.
    public func timelineTarget(from current: Double, duration: Double?) -> Double {
        let here = current.isFinite ? max(current, 0) : 0
        let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let target: Double = switch self {
        case .lineUp: here - Self.timelineLineStep
        case .lineDown: here + Self.timelineLineStep
        case .pageUp: here - Self.timelinePageStep
        case .pageDown: here + Self.timelinePageStep
        case .top: 0
        case .end: length ?? here
        }
        return min(max(target, 0), length ?? .infinity)
    }
}
