import AppKit
import DirnexCore

/// Copying a change from one file to the other (PLAN.md §M33 Slice 2): Copy to Right (⌥⌘→), Copy to
/// Left (⌥⌘←), the toolbar's two arrows, and the window's own undo.
///
/// A copy is a `LineEdit` on one side's document, built by the core from the current change of a
/// comparison of the sides as they stand. The pair is then compared again, and the change below the
/// copied lines becomes the current one. Each edit registers its inverse with `edits`, the window's
/// undo manager. Edit ▸ Undo reaches it through `NSWindow`: probed 2026-10-25, a read-only text view
/// does not answer `undo:`, so the action walks on to the window, which asks its delegate for the
/// manager and titles the item after the action ("Undo Copy to Right").
extension CompareWindowController {
    static let sides: [ComparisonPaneText.Side] = [.left, .right]

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        edits
    }

    func source(on side: ComparisonPaneText.Side) -> CompareSource {
        side == .left ? left : right
    }

    /// The side the file `id` is on now, after any Swap Sides.
    func side(ofFile id: UUID) -> ComparisonPaneText.Side? {
        if left.id == id { return .left }
        if right.id == id { return .right }
        return nil
    }

    /// The sides no copy may go to because the file would not come back byte for byte, which the
    /// banner names. Empty in a window that takes no copies at all, which shows no copy buttons.
    var readOnlySides: [ComparisonPaneText.Side] {
        guard allowsCopies else { return [] }
        return Self.sides.filter { !source(on: $0).document.isSavable }
    }

    /// Whether a copy to `side` would go through now: there is a current change, it belongs to a
    /// comparison of the sides as they stand, and the file there takes copies.
    func canCopy(to side: ComparisonPaneText.Side) -> Bool {
        guard allowsCopies, source(on: side).document.isSavable, comparedRevision == sidesRevision,
              let comparison, let currentChange else { return false }
        return comparison.diff.changes.indices.contains(currentChange)
    }

    func refreshCopyControls() {
        toolbar.enableCopy(toLeft: canCopy(to: .left), toRight: canCopy(to: .right))
    }

    /// Copy the current change across to `side`, then go on to the next change.
    func copyCurrentChange(to side: ComparisonPaneText.Side) {
        guard canCopy(to: side), let comparison, let currentChange else { return NSSound.beep() }
        let edit = LineEdit.copying(
            comparison.diff.changes[currentChange],
            to: side,
            left: left.document,
            right: right.document
        )
        apply(edit, toFile: source(on: side).id, named: CompareToolbar.copyTitle(to: side))
    }

    /// Apply `edit` to the file `id` names, wherever it is now, register the edit that undoes it,
    /// and compare the two files again.
    func apply(_ edit: LineEdit, toFile id: UUID, named name: String) {
        guard let side = side(ofFile: id) else { return }
        let inverse = side == .left ? left.document.apply(edit) : right.document.apply(edit)
        let undoing = edits.isUndoing
        edits.registerUndo(withTarget: self) { controller in
            controller.apply(inverse, toFile: id, named: name)
        }
        edits.setActionName(name)
        sidesRevision += 1
        refreshCopyControls()
        // The other file's lines did not move, so its line at the top is the one to keep there.
        let other: ComparisonPaneText.Side = side == .left ? .right : .left
        let kept = topLine(on: other).map { KeptLine(side: other, line: $0) }
        compute(options: toolbar.options, keeping: kept) { comparison in
            Self.changeToShow(after: inverse.range, on: side, in: comparison, undoing: undoing)
        }
    }

    /// The change to make current once `side`'s lines `edited` have been compared again.
    ///
    /// After a copy, or its redo, the copied lines agree, so it is the first change below them. After
    /// an undo, the change the copy took away is back on those lines, so it is that one. With no
    /// change below, it is the last one, so a current change stays while any is left.
    static func changeToShow(
        after edited: Range<Int>,
        on side: ComparisonPaneText.Side,
        in comparison: TextComparison,
        undoing: Bool
    ) -> Int? {
        let ranges = comparison.diff.changes.map { side == .left ? $0.left : $0.right }
        // Changes are kept apart by an unchanged line, so only the one on the edited lines touches
        // them.
        if undoing, let restored = ranges.firstIndex(where: {
            $0.upperBound >= edited.lowerBound && $0.lowerBound <= edited.upperBound
        }) {
            return restored
        }
        return ranges.firstIndex { $0.lowerBound >= edited.upperBound } ?? ranges.indices.last
    }
}
