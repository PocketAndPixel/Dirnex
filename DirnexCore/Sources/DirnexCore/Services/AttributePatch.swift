import Foundation

/// What a *multi-selection* attributes edit intends, expressed so it can be applied to several items
/// that do not start from the same attributes (PLAN.md §M14 Slice 4).
///
/// The single-item panel edits a whole ``FileAttributes`` value and diffs it against what was read.
/// That cannot work across a mixed selection: if two files disagree on the group-write bit and the
/// user toggles only owner-read, the group-write bit must stay whatever each file already had. A
/// whole-value diff would carry one file's group-write bit onto the other. So a bulk edit is a
/// **patch**, not a value — a set of "force this bit / this field, leave everything else" — and it is
/// turned into a per-item ``AttributeDiff`` against *that item's* current attributes, after which the
/// existing ``AttributeChangePlan`` / ``FileAttributeIO`` / undo path run unchanged, once per item.
///
/// The mode part reuses ``POSIXPermissions`` as a bit container in two roles — ``permissionMask``
/// marks *which* of the twelve bits the user set, ``permissionValues`` holds their target values —
/// so building and testing it goes through the same tested subscript and special-bit accessors the
/// panel already uses. Only the raw bits of those two matter; their `octalString` / `symbolicString`
/// are meaningless on a mask and are never read.
///
/// Owner is deliberately absent: `chown` to another user is `EPERM` even on your own file (M14
/// probe), so it is never offered, in bulk or singly. Group is a single chosen id applied to all, or
/// left untouched. ACLs are absent for a different reason — an ordered, kind-dependent list has no
/// meaningful "apply a diff to N items", so bulk editing does not touch them.
public struct AttributePatch: Sendable, Equatable {
    /// Which of the twelve mode bits the edit forces (a bit-set; string accessors are meaningless).
    public var permissionMask: POSIXPermissions
    /// The target values for the bits named in ``permissionMask``. Bits outside the mask are ignored.
    public var permissionValues: POSIXPermissions
    /// `UF_*` flags to force **on**, whatever each item had.
    public var flagsToSet: BSDFileFlags
    /// `UF_*` flags to force **off**. Never overlaps ``flagsToSet``.
    public var flagsToClear: BSDFileFlags
    /// The group to move every item to, or `nil` to leave each item's group alone.
    public var groupID: UInt32?
    /// Times to set on every item, or `nil` to leave each item's own.
    public var accessDate: Date?
    public var modificationDate: Date?
    public var creationDate: Date?

    /// An empty patch — nothing forced, every field left as it is.
    public init() {
        permissionMask = POSIXPermissions(rawValue: 0)
        permissionValues = POSIXPermissions(rawValue: 0)
        flagsToSet = []
        flagsToClear = []
    }

    /// Nothing is forced, so applying this to any item is a no-op the caller can skip.
    public var isEmpty: Bool {
        permissionMask.rawValue == 0 && flagsToSet.isEmpty && flagsToClear.isEmpty
            && groupID == nil && accessDate == nil && modificationDate == nil && creationDate == nil
    }

    /// The full attributes one item ends up with after this patch — the forced bits and fields
    /// replaced, everything else left as the item carried it. The primitive the panel uses to build
    /// each item's `new` value for the undo record, and what ``diff(against:)`` derives from.
    public func apply(to current: FileAttributes) -> FileAttributes {
        var result = current

        // Mode: replace only the masked bits, keeping the rest — `(cur & ~mask) | (val & mask)`.
        let mask = permissionMask.rawValue
        if mask != 0 {
            result.permissions = POSIXPermissions(
                rawValue: (current.permissions.rawValue & ~mask) | (permissionValues.rawValue & mask)
            )
        }

        // Flags: force the two sets on/off, leaving every other bit (including SF_* and SF_DATALESS)
        // exactly as the item carried it — the same preservation the single-item editor does.
        result.flags.formUnion(flagsToSet)
        result.flags.subtract(flagsToClear)

        if let groupID { result.groupID = groupID }
        if let accessDate { result.accessDate = accessDate }
        if let modificationDate { result.modificationDate = modificationDate }
        if let creationDate { result.creationDate = creationDate }

        return result
    }

    /// The concrete change this patch makes to one item, as the ``AttributeDiff`` the rest of the
    /// pipeline already consumes — empty for a field the patch leaves alone or that the item already
    /// matches, so a bulk edit still writes only what actually differs, item by item.
    public func diff(against current: FileAttributes) -> AttributeDiff {
        AttributeDiff(from: current, to: apply(to: current))
    }
}
