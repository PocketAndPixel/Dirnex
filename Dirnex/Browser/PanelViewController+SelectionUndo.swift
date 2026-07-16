import AppKit
import DirnexCore

/// The pane's half of selection undo/redo (PLAN.md §M2 "Undo journal", extended to marks): a
/// tiny recorder the marking gestures wrap around, and the setter the window calls back into
/// when Cmd+Z reverses one. The ordering, inversion, and redo-stack bookkeeping all live in the
/// window's `UndoController`/core `UndoJournal`; the pane only reports what changed and re-marks.
extension PanelViewController {
    /// Journal a marking change if it actually changed the marks. Call it right after mutating
    /// `panel`, passing the marks captured *before* the mutation; an unchanged set (a re-select
    /// that marks nothing new, Space on an already-(un)marked run) records nothing, so Cmd+Z
    /// never stops on a no-op.
    ///
    /// `directory` defaults to the pane's current folder, which is right for an in-place gesture.
    /// Pass it explicitly when a navigation has already cleared the marks and moved the pane on —
    /// the entry must name the *departed* folder so undo restores the marks there, not here.
    func recordMarkChange(since previous: Set<VFSPath>, in directory: VFSPath? = nil, label: String) {
        guard panel.selection != previous else { return }
        host?.recordSelectionChange(
            on: self,
            directory: directory ?? panel.path,
            previousMarks: previous,
            label: label
        )
    }

    /// Install a set of marks from an undo/redo of a selection change, then re-render. Declines
    /// when the pane has since navigated away from `directory` — restoring marks from a directory
    /// the user has left would do nothing visible at best, so we leave the current view alone
    /// rather than silently swap in a stale, invisible mark set.
    func applyUndoSelection(_ marks: Set<VFSPath>, in directory: VFSPath) {
        guard panel.path == directory else { return }
        panel.setSelection(marks)
        resetMouseSelectionAnchor()
        reloadEverything()
        refreshQuickLookIfVisible()
    }
}
