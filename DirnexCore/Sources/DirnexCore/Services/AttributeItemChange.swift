import Foundation

/// What a recursive ``AttributeApplyJob`` asks of one item, measured against that item as it is on
/// disk now (PLAN.md §M14 Slice 4, §M40 Slice 4).
///
/// A type of its own because two callers have to agree on it exactly: the run, which writes it
/// unprivileged, and the administrator retry offered afterwards for the items the run had to leave
/// (``EscalatedAttributeBatch``). A second derivation of "what this job means for this item" would be
/// free to drift from the one that ran, and the retry would then be changing something other than
/// what the confirmation sheet described.
public struct AttributeItemChange: Sendable, Equatable {
    public let path: VFSPath
    /// The item's attributes as read for this change, and whether it is a symlink acted on itself.
    public let reading: FileAttributeIO.Reading
    /// The patch turned into this item's own diff.
    public let diff: AttributeDiff
    /// The list the job writes, already adjusted to this item's kind, or `nil` when the job leaves
    /// every item's list alone. It can equal ``existingACL``; ``changesAccessControlList`` says
    /// whether it does not.
    public let desiredACL: AccessControlList?
    /// The item's list before the change, read only when the job writes one.
    public let existingACL: AccessControlList?

    public init(
        path: VFSPath,
        reading: FileAttributeIO.Reading,
        diff: AttributeDiff,
        desiredACL: AccessControlList? = nil,
        existingACL: AccessControlList? = nil
    ) {
        self.path = path
        self.reading = reading
        self.diff = diff
        self.desiredACL = desiredACL
        self.existingACL = existingACL
    }

    /// The job writes a list and it differs from the one the item has.
    public var changesAccessControlList: Bool {
        desiredACL != nil && desiredACL != existingACL
    }

    /// Nothing to write: the item already matches the job.
    public var isEmpty: Bool { diff.isEmpty && !changesAccessControlList }

    /// The ordered syscalls that make the change, the unlock/relock and the repairs included.
    public var plan: AttributeChangePlan {
        AttributeChangePlan(
            diff: diff,
            current: reading.attributes,
            actsOnLink: reading.isSymlink,
            accessControlList: changesAccessControlList ? desiredACL : nil
        )
    }

    /// The undo material for this change, with `new` as the attributes it left. The ACL pair is
    /// there whenever the job writes a list, and ``UndoRecord/attributeBatchChange(_:date:)`` drops it
    /// when the two are equal.
    public func batchEntry(
        new: FileAttributes,
        accessControlList newACL: AccessControlList? = nil
    ) -> UndoRecord.AttributeBatchEntry {
        let written = newACL ?? desiredACL
        let lists: (old: AccessControlList, new: AccessControlList)? =
            if let written { (old: existingACL ?? AccessControlList(), new: written) } else { nil }
        return UndoRecord.AttributeBatchEntry(
            path: path,
            actsOnLink: reading.isSymlink,
            old: reading.attributes,
            new: new,
            accessControlLists: lists
        )
    }

    /// Why the change needs root for `actor`, if it does.
    public func reasons(for actor: UserContext) -> [AttributePrivilege.Reason] {
        AttributePrivilege.reasons(
            for: diff,
            current: reading.attributes,
            actor: actor,
            changesAccessControlList: changesAccessControlList
        )
    }
}

public extension AttributeApplyJob {
    /// Read the item at `path` and work out what this job would write to it.
    ///
    /// The ACL is adjusted to the item's `kind` *before* anything is compared, so a file that would
    /// receive a directory's list unchanged counts as already matching whenever the adjusted list is
    /// what it has: no write, no journal entry, no undo step.
    func change(at path: VFSPath, kind: FileEntry.Kind) throws -> AttributeItemChange {
        let reading = try FileAttributeIO.read(at: path)
        let desiredACL = accessControlList?.adjusted(for: kind)
        let existingACL = desiredACL == nil
            ? nil
            : try? AccessControlListIO.read(at: path, actsOnLink: reading.isSymlink)
        return AttributeItemChange(
            path: path,
            reading: reading,
            diff: patch.diff(against: reading.attributes),
            desiredACL: desiredACL,
            existingACL: existingACL
        )
    }
}
