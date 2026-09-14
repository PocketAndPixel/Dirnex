import Foundation

/// The steps ⌘+ and ⌘− walk a Quick View preview through, and what ⌘0 goes back to (2026-09-14).
///
/// One ladder for every backend that zooms — a web page, a PDF, a text file — so the keys feel the
/// same whichever file is under the cursor. The values are a browser's, because a browser is where
/// people learned these keys: fine steps near 100 %, where a small change is what reading needs,
/// and wide ones far from it, where the point is to get somewhere.
///
/// A zoom here is always *relative to how the preview first drew the file*. A Word page fitted to
/// the surface is already scaled, and a sheet is at its own size; 1 is that starting point in both
/// cases, so ⌘0 means "as it opened" and a step means "a bit larger than that" rather than jumping to
/// an absolute 100 % the user never saw.
public enum QuickViewZoom {
    /// Which way a step goes.
    public enum Direction: Sendable {
        case larger
        case smaller
    }

    /// The zoom levels, smallest first. The starting point, 1, is on the ladder, so stepping away and
    /// back again returns there exactly.
    public static let levels: [Double] = [
        0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5
    ]

    /// The level a step from `current` lands on, or `nil` when there is none that way — the key does
    /// nothing at the end of the ladder, and a menu item for it is disabled.
    ///
    /// `current` need not be on the ladder: a pinch leaves the preview anywhere, and the next step
    /// then goes to the nearest level strictly past it rather than snapping backwards first. The
    /// tolerance absorbs the rounding a view's own scale comes back with, so a preview sitting at
    /// 1.25 does not "step" to 1.25.
    public static func step(from current: Double, _ direction: Direction) -> Double? {
        let tolerance = 0.005
        switch direction {
        case .larger:
            return levels.first { $0 > current + tolerance }
        case .smaller:
            return levels.last { $0 < current - tolerance }
        }
    }
}
