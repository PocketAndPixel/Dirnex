import Foundation

/// One local attribute step of an undo or a redo, measured against its item as it is now: what is
/// left to write, and so whether writing it needs root (PLAN.md §M40 Slice 5).
///
/// The executor (``UndoJournal/restoreAttributes(_:at:actsOnLink:actor:failures:)``) and the
/// escalation (``EscalatedUndo``) both measure through this, and that is the reason it is a type. The
/// escalation decides which steps go to root and which it leaves for the executor, and a step it
/// leaves must never then be refused by the executor for root. Two derivations of "does this step
/// need root" would be free to disagree, and the disagreement would read as a refusal after a
/// password the user had just typed.
///
/// **Only what still differs counts.** A field the item already holds is dropped before the privilege
/// question is asked, and so is a list it already has. Someone who ran the dialog's command in
/// Terminal themselves and then pressed Cancel gets a ⌘Z that finds nothing left to write, rather
/// than a second password dialog for values already on disk. Dropping them changes no write:
/// ``AttributeChangePlan`` leaves a field it is not given at the value it reads now, and both of its
/// repairs (the set-id bits a `chown` clears, the birth time an earlier `mtime` drags back) read the
/// current value too.
struct LocalAttributeRestore: Sendable, Equatable {
    let path: VFSPath
    let actsOnLink: Bool
    /// The item's attributes now.
    let current: FileAttributes
    /// The step's fields that differ from ``current``.
    let diff: AttributeDiff
    /// The list still to write: `nil` when the step writes none, or the item already has it.
    let accessControlList: AccessControlList?
    /// The item's list now, read only when the step writes one, and `nil` if it could not be read.
    let existingAccessControlList: AccessControlList?

    /// Read the item at `path` and measure `diff` and `list` against it. Throws what the read throws,
    /// a missing item included. A list that cannot be read counts as different, so it is written, as
    /// it always was.
    init(
        path: VFSPath,
        actsOnLink: Bool,
        diff: AttributeDiff,
        accessControlList list: AccessControlList? = nil
    ) throws {
        self.path = path
        self.actsOnLink = actsOnLink
        current = try FileAttributeIO.read(at: path).attributes
        self.diff = diff.remaining(against: current)
        if let list {
            let existing = try? AccessControlListIO.read(at: path, actsOnLink: actsOnLink)
            existingAccessControlList = existing
            accessControlList = existing == list ? nil : list
        } else {
            existingAccessControlList = nil
            accessControlList = nil
        }
    }

    /// Nothing is left to write.
    var isEmpty: Bool { diff.isEmpty && accessControlList == nil }

    /// Whether what is left needs root for `actor`.
    func needsRoot(for actor: UserContext) -> Bool {
        AttributePrivilege.needsRoot(
            for: diff,
            current: current,
            actor: actor,
            changesAccessControlList: accessControlList != nil
        )
    }

    /// The ordered syscalls that write what is left, the unlock and relock included.
    var plan: AttributeChangePlan {
        AttributeChangePlan(
            diff: diff,
            current: current,
            actsOnLink: actsOnLink,
            accessControlList: accessControlList
        )
    }

    /// The same change, as one item of an administrator batch.
    var batchItem: EscalatedAttributeBatch.Item {
        EscalatedAttributeBatch.Item(
            path: path,
            actsOnLink: actsOnLink,
            current: current,
            diff: diff,
            currentACL: existingAccessControlList,
            accessControlList: accessControlList
        )
    }
}

extension AttributeDiff {
    /// The fields of this diff whose values differ from `current`: what writing it would still change.
    func remaining(against current: FileAttributes) -> AttributeDiff {
        var left = AttributeDiff()
        if let value = permissions, value != current.permissions { left.permissions = value }
        if let value = flags, value != current.flags { left.flags = value }
        if let value = ownerID, value != current.ownerID { left.ownerID = value }
        if let value = groupID, value != current.groupID { left.groupID = value }
        if let value = accessDate, value != current.accessDate { left.accessDate = value }
        if let value = modificationDate, value != current.modificationDate {
            left.modificationDate = value
        }
        if let value = creationDate, value != current.creationDate { left.creationDate = value }
        return left
    }

    /// This diff with every field `later` sets taken from `later`: the two applied one after the other.
    func overlaid(by later: AttributeDiff) -> AttributeDiff {
        var merged = self
        if let value = later.permissions { merged.permissions = value }
        if let value = later.flags { merged.flags = value }
        if let value = later.ownerID { merged.ownerID = value }
        if let value = later.groupID { merged.groupID = value }
        if let value = later.accessDate { merged.accessDate = value }
        if let value = later.modificationDate { merged.modificationDate = value }
        if let value = later.creationDate { merged.creationDate = value }
        return merged
    }
}
