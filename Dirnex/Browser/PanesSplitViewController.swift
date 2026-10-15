import AppKit

/// The split between the two file panes, whose divider holds still for a moment where the panes are
/// the same width.
///
/// Dragging the divider to an even split by eye is hard: there is nothing to aim at, and a point or
/// two off is invisible until the columns don't line up. So a drag that comes within
/// `equalWidthDetent` of the halfway position puts the divider exactly there and keeps it there
/// until the pointer leaves the band again. Entering the band also taps the trackpad, the same
/// feedback macOS gives when a dragged object meets an alignment guide.
@MainActor
final class PanesSplitViewController: LockableDividerSplitViewController {
    /// How far either side of the even split the divider holds. Eight points gives sixteen points of
    /// pointer travel during which the divider stays put, which is enough to feel and too little for
    /// anyone to want the divider somewhere inside it.
    static let equalWidthDetent: CGFloat = 8

    /// Runs as a drag enters the detent. Swapped by tests, which cannot feel a trackpad.
    var detentFeedback: () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// The divider position that gives both panes the same width.
    static func equalPosition(in splitView: NSSplitView) -> CGFloat {
        (splitView.bounds.width - splitView.dividerThickness) / 2
    }

    /// Where a drag proposing `proposed` puts the divider: on `equal` inside the detent, under the
    /// pointer outside it.
    static func position(for proposed: CGFloat, equal: CGFloat) -> CGFloat {
        abs(proposed - equal) <= equalWidthDetent ? equal : proposed
    }

    // `NSSplitViewController` itself does not implement this delegate method (probed:
    // `instancesRespond(to:)` is false), so there is no `super` to call. AppKit sends it for every
    // step of a drag, and once for a programmatic `setPosition(_:ofDividerAt:)`.
    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let equal = Self.equalPosition(in: splitView)
        let position = Self.position(for: proposedPosition, equal: equal)
        // The leading pane's width is still the previous step's position when this runs, so it says
        // whether the drag is entering the detent or already inside it. Only a drag gets the tap: a
        // programmatic `setPosition` (the first launch's centering) arrives here too.
        if position == equal, let leading = splitView.subviews.first,
           abs(leading.frame.width - equal) > Self.equalWidthDetent,
           NSApp.currentEvent?.type == .leftMouseDragged {
            detentFeedback()
        }
        return position
    }
}
