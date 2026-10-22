import AppKit
import DirnexCore

/// Moving between changes in the compare window (PLAN.md §M31 Slice 3): the toolbar's arrows,
/// ⌥⌘↓ and ⌥⌘↑, and a click in the overview strip. Split out of the controller when Swap Sides
/// took it past the type-body ceiling.
extension CompareWindowController {
    func goToChange(_ index: Int) {
        guard let comparison, comparison.changeRows.indices.contains(index) else { return }
        currentChange = index
        band.current = index
        toolbar.showCounter(current: index, count: comparison.changeRows.count)
        sync?.reveal(row: comparison.changeRows[index].lowerBound)
    }

    func goToNextChange() {
        guard let comparison else { return }
        let next: Int? = if let currentChange {
            currentChange + 1 < comparison.changeRows.count ? currentChange + 1 : nil
        } else {
            comparison.changeRows.firstIndex { $0.lowerBound >= (
                leftPane.textView.rowAtTop()?.row ?? 0
            ) }
        }
        guard let next else { return NSSound.beep() }
        goToChange(next)
    }

    func goToPreviousChange() {
        guard let comparison else { return }
        let previous: Int? = if let currentChange {
            currentChange > 0 ? currentChange - 1 : nil
        } else {
            comparison.changeRows.lastIndex { $0.lowerBound < (
                leftPane.textView.rowAtTop()?.row ?? 0
            ) }
        }
        guard let previous else { return NSSound.beep() }
        goToChange(previous)
    }

    /// Show `row`, from the overview strip: no change is the current one after that.
    func jump(toRow row: Int) {
        currentChange = nil
        band.current = nil
        toolbar.showCounter(current: nil, count: comparison?.changeRows.count ?? 0)
        sync?.reveal(row: row)
    }
}
