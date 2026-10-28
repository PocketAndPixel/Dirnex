import AppKit

/// Which row a Force Click on the file list is for, read from one press's pressure events.
///
/// AppKit reports a press on a Force Touch trackpad as `.pressure` events whose `stage` is 1 for the
/// ordinary click, 2 once it is pressed on into the deeper second click, and 0 at the release.
/// Measured 2026-10-18 on this table with a real trackpad: none of them arrives while the button is
/// down. `NSTableView.mouseDown` runs its own tracking loop, which leaves them in the queue, and the
/// whole press is delivered in one burst once the button is up. So the answer comes on release, after
/// the click has moved the cursor, and never inside a tracking loop.
///
/// A value of its own rather than a few lines on the table because `NSEvent` has no factory for a
/// pressure event, so the stages are only testable as numbers.
struct ForceClickRecognizer {
    /// The row of the press that may still become a Force Click, or `nil`.
    private var armedRow: Int?

    /// A plain single click began on `row`.
    mutating func arm(row: Int) {
        armedRow = row
    }

    /// A press that is not a Force Click for a row: ⌘ or ⇧ held, a second click, empty space, a
    /// disclosure triangle. Also a press that turned into a drag, so pressing hard mid-drag does not
    /// rename the row after the drop.
    mutating func disarm() {
        armedRow = nil
    }

    /// The press reached pressure `stage`. Returns the armed row the first time the press reaches
    /// stage 2 and `nil` for every other event, so a press answers once. The release (stage 0) also
    /// disarms, so a later press that arms nothing cannot inherit this one's row.
    mutating func pressureChanged(toStage stage: Int) -> Int? {
        switch stage {
        case 0:
            armedRow = nil
            return nil
        case 2...:
            let row = armedRow
            armedRow = nil
            return row
        default:
            return nil
        }
    }
}

extension FileTableView {
    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        forceClickStageChanged(to: event.stage)
    }

    /// Internal for the tests, which cannot make the pressure event that calls it.
    func forceClickStageChanged(to stage: Int) {
        guard let row = forceClick.pressureChanged(toStage: stage) else { return }
        inputDelegate?.fileTable(self, didForceClickRow: row)
    }
}
