import Foundation

public extension UndoRecord {
    /// The undo record for a copy or move job, read from its whole report: the items that finished,
    /// as ``transfer(kind:outcomes:date:)`` reads them, and the one a Stop caught partway
    /// (``OperationReport/stoppedPartway``).
    ///
    /// **The item caught partway is undone by removing what of it was written, for a move as for a
    /// copy.** A move takes its source away only once the whole item has been written, so that
    /// source never left, and moving the partial copy back would land on it. Without this, Stop on
    /// one big folder left its finished files behind with no record at all, while the question
    /// that asked said "⌘Z undoes it" (PLAN.md §M41 Slice 3). Redo, `removeCopy`'s inverse, then
    /// copies the whole item again: more than the Stop left, never less.
    static func transfer(
        kind: FileOperation.Kind,
        report: OperationReport,
        date: Date = Date()
    ) -> UndoRecord? {
        let finished = transfer(kind: kind, outcomes: report.outcomes, date: date)
        let label: UndoActionLabel
        switch kind {
        case .copy: label = .copy
        case .move: label = .move
        // Only the copy engine stops partway, and it runs nothing else.
        default: return finished
        }
        guard let stopped = report.stoppedPartway, let landed = stopped.landedAt else {
            return finished
        }
        return UndoRecord(
            label: label,
            date: date,
            steps: (finished?.steps ?? []) + [.removeCopy(source: stopped.source, copy: landed)],
            // Counted from the outcomes rather than taken from `finished`, which is `nil` when every
            // finished item overwrote something.
            nonReversibleCount: report.outcomes.count(
                where: { $0.landedAt != nil && $0.replacedExisting }
            )
        )
    }
}
