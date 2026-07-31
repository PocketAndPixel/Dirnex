import Foundation

// The attributes-change corner of the undo journal (PLAN.md §M14 Slice 4), split out of
// `UndoJournal.swift` so the file that owns the copy/move/folder machinery stays under the 500-line
// ceiling (docs/NOTES.md §"Lint ceilings"). Two halves: the record `attributeChange` builds after a
// panel commit, and the `restoreAttributes` executor `UndoJournal.revert` dispatches to.
//
// The whole reason this is a *separate* concept is the last line of `UndoStep.restoreAttributes`'s
// doc: an attribute change is undone through `FileAttributeIO`'s syscalls, not through a `VFSBackend`
// verb, so its executor sits beside the backend-driven ones but does not use the backend at all.

public extension UndoRecord {
    /// Undo an attributes change (mode bits and BSD flags this pass; owner, group and times later)
    /// by restoring every field the edit touched to its prior value — one step, so a single Cmd+Z
    /// reverses the whole panel commit. `old`/`new` are the full attributes read before the edit and
    /// left after it: the forward diff (`old → new`) is what redo re-applies, and its mirror
    /// (`new → old`) is what undo restores, so the step carries both and `inverse` swaps them.
    /// Returns `nil` when nothing actually changed — an all-no-op commit never enters the journal.
    static func attributeChange(
        at path: VFSPath,
        actsOnLink: Bool,
        from old: FileAttributes,
        to new: FileAttributes,
        date: Date = Date()
    ) -> UndoRecord? {
        let forward = AttributeDiff(from: old, to: new)
        guard !forward.isEmpty else { return nil }
        return UndoRecord(
            label: .changeAttributes,
            date: date,
            steps: [.restoreAttributes(
                path: path,
                actsOnLink: actsOnLink,
                apply: AttributeDiff(from: new, to: old),
                reverse: forward
            )]
        )
    }
}

extension UndoJournal {
    /// Re-apply a set of attribute values (mode bits and flags this pass) to a local item, reading
    /// its current attributes first so the ordered plan sequences the unlock/relock around whatever
    /// is on disk now. Bypasses the `VFSBackend` because attribute I/O is a local syscall path
    /// (``FileAttributeIO``), not a backend verb. An empty diff is nothing to do; any failure is
    /// collected like every other step so undoing a batch never aborts on one bad path.
    static func restoreAttributes(
        _ diff: AttributeDiff,
        at path: VFSPath,
        actsOnLink: Bool,
        failures: inout [OperationItemFailure]
    ) {
        guard !diff.isEmpty else { return }
        do {
            let current = try FileAttributeIO.read(at: path).attributes
            let plan = AttributeChangePlan(diff: diff, current: current, actsOnLink: actsOnLink)
            try FileAttributeIO.apply(plan, to: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }
}
