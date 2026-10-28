import AppKit
import DirnexCore

/// Moving between conflicts and choosing for them (PLAN.md §M34 Slice 3): ⌥⌘↓ and ⌥⌘↑, the
/// toolbar's arrows and a click in the overview strip; and the four takes, ⌥⌘→ Take Yours, ⌥⌘←
/// Take Theirs, and with ⇧ both sides, the arrow's side first.
///
/// A take is a `TextMerge.Step` on the current conflict, and its inverse is registered with the
/// window's undo manager, so Edit ▸ Undo names it ("Undo Take Yours") and opens the conflict again
/// or puts the earlier choice back. After a take the next open conflict is current, as the compare
/// window goes on to the next change after a copy; after an undo, the conflict it changed.
extension MergeWindowController {
    func goToConflict(_ conflict: Int) {
        guard let merge, merge.choices.indices.contains(conflict) else { return }
        currentConflict = conflict
        refreshControls()
        guard let shown, shown.conflictRows.indices.contains(conflict) else { return }
        sync?.reveal(row: shown.conflictRows[conflict].lowerBound)
    }

    func goToNextConflict() {
        guard let merge, let shown else { return }
        let next: Int? = if let currentConflict {
            currentConflict + 1 < merge.choices.count ? currentConflict + 1 : nil
        } else {
            shown.conflictRows.firstIndex { $0.lowerBound >= topRow }
        }
        guard let next else { return NSSound.beep() }
        goToConflict(next)
    }

    func goToPreviousConflict() {
        guard let shown else { return }
        let previous: Int? = if let currentConflict {
            currentConflict > 0 ? currentConflict - 1 : nil
        } else {
            shown.conflictRows.lastIndex { $0.lowerBound < topRow }
        }
        guard let previous else { return NSSound.beep() }
        goToConflict(previous)
    }

    /// The row at the top of the panes.
    private var topRow: Int {
        yoursPane.textView.rowAtTop()?.row ?? 0
    }

    /// Show `row`, from the overview strip. The conflict holding it is current then, or none.
    func jump(toRow row: Int) {
        currentConflict = shown?.conflictRows.firstIndex { $0.contains(row) }
        refreshControls()
        sync?.reveal(row: row)
    }

    // MARK: - Taking

    /// Take `choice` for the current conflict, then go on to the next open one.
    func take(_ choice: TextMerge.Choice) {
        guard let currentConflict, merge != nil else { return NSSound.beep() }
        apply(
            TextMerge.Step(conflict: currentConflict, choice: choice),
            named: MergeToolbar.takeTitle(choice)
        )
    }

    /// Make `step`'s choice, register the step that undoes it under `name`, and show the merge
    /// again. A choice the conflict already has changes nothing and goes on all the same.
    func apply(_ step: TextMerge.Step, named name: String) {
        guard var merge else { return }
        let inverse = merge.apply(step)
        self.merge = merge
        let undoing = edits.isUndoing
        if inverse != step {
            // One take is one step, grouped here rather than by the event. An undo or a redo
            // registers its inverse into the group the manager opened for it.
            let grouping = !edits.isUndoing && !edits.isRedoing
            if grouping { edits.beginUndoGrouping() }
            edits.registerUndo(withTarget: self) { controller in
                controller.apply(inverse, named: name)
            }
            edits.setActionName(name)
            if grouping { edits.endUndoGrouping() }
            choicesMade += 1
        }
        currentConflict = undoing
            ? step.conflict
            : Self.nextOpenConflict(after: step.conflict, in: merge.choices) ?? step.conflict
        refreshControls()
        prepare(revealing: currentConflict)
    }

    /// The first conflict after `conflict` with no choice, going round to the start, or `nil` when
    /// every other one has a choice.
    static func nextOpenConflict(after conflict: Int, in choices: [TextMerge.Choice?]) -> Int? {
        guard choices.count > 1 else { return nil }
        return (1..<choices.count).lazy
            .map { (conflict + $0) % choices.count }
            .first { choices[$0] == nil }
    }
}
