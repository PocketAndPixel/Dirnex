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
        accessControlList lists: (old: AccessControlList, new: AccessControlList)? = nil,
        date: Date = Date()
    ) -> UndoRecord? {
        let forward = AttributeDiff(from: old, to: new)
        var steps: [UndoStep] = []
        if !forward.isEmpty {
            steps.append(.restoreAttributes(
                path: path,
                actsOnLink: actsOnLink,
                apply: AttributeDiff(from: new, to: old),
                reverse: forward
            ))
        }
        // The ACL is its own step in the *same* record, so one Cmd+Z reverses the whole panel commit
        // — the sheet applies both halves on one Save, and an undo that put back the mode bits and
        // left a new deny entry standing would be worse than no undo at all.
        if let lists, lists.old != lists.new {
            steps.append(.restoreAccessControlList(
                path: path,
                actsOnLink: actsOnLink,
                apply: lists.old,
                reverse: lists.new
            ))
        }
        guard !steps.isEmpty else { return nil }
        return UndoRecord(label: .changeAttributes, date: date, steps: steps)
    }

    /// One item's before/after for a multi-selection commit. A struct rather than a tuple because a
    /// four-member tuple trips SwiftLint's `large_tuple`, and because naming the fields is what keeps
    /// `old` and `new` from being handed over in the wrong order.
    struct AttributeBatchEntry: Sendable {
        public let path: VFSPath
        public let actsOnLink: Bool
        public let old: FileAttributes
        public let new: FileAttributes

        public init(path: VFSPath, actsOnLink: Bool, old: FileAttributes, new: FileAttributes) {
            self.path = path
            self.actsOnLink = actsOnLink
            self.old = old
            self.new = new
        }
    }

    /// Undo a **multi-selection** attributes commit — one ``UndoStep/restoreAttributes`` per item that
    /// actually changed, gathered into a single record so one Cmd+Z reverses the whole batch (the
    /// Multi-Rename precedent, PLAN.md §M4). Items whose diff is empty contribute no step, so a bulk
    /// edit that happened to match a few items already never journals a no-op for them; `nil` when no
    /// item changed at all. There is no ACL half here — bulk editing does not touch ACLs.
    static func attributeBatchChange(
        _ entries: [AttributeBatchEntry],
        date: Date = Date()
    ) -> UndoRecord? {
        let steps: [UndoStep] = entries.compactMap { entry in
            let forward = AttributeDiff(from: entry.old, to: entry.new)
            guard !forward.isEmpty else { return nil }
            return .restoreAttributes(
                path: entry.path,
                actsOnLink: entry.actsOnLink,
                apply: AttributeDiff(from: entry.new, to: entry.old),
                reverse: forward
            )
        }
        guard !steps.isEmpty else { return nil }
        return UndoRecord(label: .changeAttributes, date: date, steps: steps)
    }
}

extension UndoJournal {
    /// Re-apply a set of attribute values to a local item, reading its current attributes first so
    /// the ordered plan sequences the unlock/relock around whatever is on disk now. Bypasses the
    /// `VFSBackend` because attribute I/O is a local syscall path (``FileAttributeIO``), not a
    /// backend verb. An empty diff is nothing to do; any failure is collected like every other step
    /// so undoing a batch never aborts on one bad path.
    ///
    /// **An undo can need privileges the original change did not**, which is not symmetric and is
    /// easy to miss: the panel's group picker offers the groups the user belongs to *plus* the item's
    /// current one, so moving a file out of a group they are not in is legal and moving it back is
    /// `EPERM`. Checking ``AttributePrivilege`` first is what turns that into a sentence naming the
    /// cause instead of a bare errno the app renders as "Dirnex may need Full Disk Access" — the same
    /// "an EPERM that needs root is indistinguishable from one that does not" trap the whole
    /// attributes design is built around, arriving here from the other direction.
    static func restoreAttributes(
        _ diff: AttributeDiff,
        at path: VFSPath,
        actsOnLink: Bool,
        failures: inout [OperationItemFailure]
    ) {
        guard !diff.isEmpty else { return }
        do {
            let current = try FileAttributeIO.read(at: path).attributes
            let needsRoot = AttributePrivilege.needsRoot(
                for: diff, current: current, actor: .current()
            )
            guard !needsRoot else {
                let reason = VFSUnsupportedReason
                    .attributeRestoreNeedsAdministrator(name: path.lastComponent)
                failures.append(.init(path: path, error: .unsupported(reason)))
                return
            }
            let plan = AttributeChangePlan(diff: diff, current: current, actsOnLink: actsOnLink)
            try FileAttributeIO.apply(plan, to: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }

    /// Put a whole access-control list back — the ACL half of an undone attributes commit.
    ///
    /// It goes through an ``AttributeChangePlan`` rather than calling ``AccessControlListIO`` outright
    /// for one reason, and it is the same one the mode path has: `acl_set_file` is `EPERM` while the
    /// item is immutable (probed), so restoring an ACL on a file the user locked *after* the edit has
    /// to unlock, write and relock exactly as the forward change did. Reading the current attributes
    /// first is what makes that depend on what is on disk now.
    ///
    /// The privilege check is the same asymmetry ``restoreAttributes`` guards: nothing about a file
    /// the user no longer owns is theirs to put back, and a bare `EPERM` here renders as a Full Disk
    /// Access sentence that cannot help.
    static func restoreAccessControlList(
        _ list: AccessControlList,
        at path: VFSPath,
        actsOnLink: Bool,
        failures: inout [OperationItemFailure]
    ) {
        do {
            let current = try FileAttributeIO.read(at: path).attributes
            let needsRoot = AttributePrivilege.needsRoot(
                for: AttributeDiff(),
                current: current,
                actor: .current(),
                changesAccessControlList: true
            )
            guard !needsRoot else {
                let reason = VFSUnsupportedReason
                    .attributeRestoreNeedsAdministrator(name: path.lastComponent)
                failures.append(.init(path: path, error: .unsupported(reason)))
                return
            }
            let plan = AttributeChangePlan(
                diff: AttributeDiff(),
                current: current,
                actsOnLink: actsOnLink,
                accessControlList: list
            )
            try FileAttributeIO.apply(plan, to: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }
}
