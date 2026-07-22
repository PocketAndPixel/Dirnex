import Foundation

/// Turns the stream of scroll deltas a two-finger trackpad swipe produces into discrete
/// "step one row" decisions — the gesture that flips between files while a full-size Quick View
/// covers the list (PLAN.md §M11), the pointing-device twin of ← / →.
///
/// Pure and headless, so the two ways this runs away are pinned by tests rather than by a finger:
/// a flick's *momentum* would otherwise coast through the whole folder after the fingers lift, and
/// a mostly-vertical scroll of a long document would flip files on its horizontal jitter.
///
/// The app maps `NSEvent` onto these values; nothing here knows what a trackpad is.
public struct SwipeStepper: Sendable {
    /// Where in the gesture an event sits. Momentum is a separate flag rather than a phase of its
    /// own, because AppKit delivers it riding along with `.changed`.
    public enum Phase: Sendable, Equatable {
        case began
        case changed
        case ended
    }

    /// How far a swipe must travel, in points, to move the cursor one row. Roughly a third of a
    /// Magic Trackpad's width — the distance Preview and Photos ask for to turn a page, so a
    /// deliberate flip lands one file and resting two fingers on the glass lands none. The one
    /// number here that wants a real hand on real hardware to confirm.
    public static let threshold: Double = 120

    /// Travel banked since the last step, in points. Signed the way the delta is.
    private var accumulated: Double = 0

    public init() {}

    /// Fold one scroll event into the gesture and answer how many rows the cursor should move:
    /// positive is *forward* through the list, negative is back, and `0` — much the commonest
    /// answer — is "not yet".
    ///
    /// `deltaX` follows the raw event, so the gesture inverts with the user's "natural scrolling"
    /// setting exactly as every other scroll on their Mac does. Under the default, fingers moving
    /// left carry the content left and bring the *next* file on from the right.
    public mutating func step(
        deltaX: Double,
        deltaY: Double,
        phase: Phase,
        isMomentum: Bool
    ) -> Int {
        // A gesture starts and ends with a clean slate: travel banked by the last swipe must not
        // add to this one, or two half-swipes make a step the user never asked for.
        if phase != .changed {
            accumulated = 0
            return 0
        }
        // The coast after the fingers lift. Honouring it would spend one flick walking the folder.
        guard !isMomentum else {
            accumulated = 0
            return 0
        }
        // Scrolling a wide document, or a page, drifts sideways; only a swipe that is *mostly*
        // horizontal is asking for the next file.
        guard abs(deltaX) > abs(deltaY) else { return 0 }
        accumulated += deltaX
        let steps = (accumulated / Self.threshold).rounded(.towardZero)
        guard steps != 0 else { return 0 }
        // Keep the remainder rather than zeroing it, so a long, steady drag keeps stepping at an
        // even rate instead of stalling for a fresh full threshold after each row.
        accumulated -= steps * Self.threshold
        return -Int(steps)
    }
}
