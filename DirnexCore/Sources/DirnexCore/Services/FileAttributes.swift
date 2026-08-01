import Foundation

/// Everything the attributes panel reads and edits for one item: permission bits, BSD flags,
/// owner/group, and the three timestamps (PLAN.md §M14 Slice 3).
///
/// A plain, `Equatable` value with no I/O of its own. The panel reads one, hands the user a mutable
/// copy, and ``AttributeDiff`` compares the two so the applier changes **only** what was actually
/// touched — a field left alone is never written, which is what lets a multi-selection apply a diff
/// rather than a value and keeps a "mixed" field mixed.
///
/// ACLs are deliberately *not* here. They are their own ordered, kind-dependent model
/// (``AccessControlList``) with their own read/write path, because a checkbox grid over a set is the
/// wrong shape for an ordered list whose entry order is meaning.
public struct FileAttributes: Sendable, Equatable {
    /// Permission bits (`mode & 0o7777`).
    public var permissions: POSIXPermissions
    /// The whole BSD flags word.
    public var flags: BSDFileFlags
    /// Owning user id.
    public var ownerID: UInt32
    /// Owning group id.
    public var groupID: UInt32
    /// Last-access time (`st_atime`). Editable via `utimes`.
    public var accessDate: Date
    /// Last-modification time (`st_mtime`). Editable via `utimes`.
    public var modificationDate: Date
    /// Birth/creation time (`st_birthtime`). Editable via `setattrlist`, not `utimes`.
    public var creationDate: Date

    public init(
        permissions: POSIXPermissions,
        flags: BSDFileFlags,
        ownerID: UInt32,
        groupID: UInt32,
        accessDate: Date,
        modificationDate: Date,
        creationDate: Date
    ) {
        self.permissions = permissions
        self.flags = flags
        self.ownerID = ownerID
        self.groupID = groupID
        self.accessDate = accessDate
        self.modificationDate = modificationDate
        self.creationDate = creationDate
    }
}

/// The changed fields between the attributes a panel read and the ones the user left it with — each
/// carrying the *desired* value, or `nil` when that field was not touched.
///
/// This is the input both to ``AttributeChangePlan`` (what to write, and in what order) and to
/// ``AttributePrivilege`` (whether any of it needs root). Building it by comparison rather than by
/// tracking edits is what makes a mixed multi-selection correct for free: a field the user never set
/// stays equal to what was read and so never appears in the diff.
///
/// `Codable` because it rides inside a persisted ``UndoStep``: an applied attribute change is a
/// reversible action, and the undo journal survives relaunch, so the changed-field values have to
/// serialize alongside the file-operation steps.
public struct AttributeDiff: Sendable, Equatable, Codable {
    public var permissions: POSIXPermissions?
    public var flags: BSDFileFlags?
    public var ownerID: UInt32?
    public var groupID: UInt32?
    public var accessDate: Date?
    public var modificationDate: Date?
    public var creationDate: Date?

    /// An empty diff (nothing changed).
    public init() {}

    /// The diff that turns `old` into `new`: a field differs → its desired value; a field matches →
    /// `nil`.
    public init(from old: FileAttributes, to new: FileAttributes) {
        if new.permissions != old.permissions { permissions = new.permissions }
        if new.flags != old.flags { flags = new.flags }
        if new.ownerID != old.ownerID { ownerID = new.ownerID }
        if new.groupID != old.groupID { groupID = new.groupID }
        if new.accessDate != old.accessDate { accessDate = new.accessDate }
        if new.modificationDate != old.modificationDate { modificationDate = new.modificationDate }
        if new.creationDate != old.creationDate { creationDate = new.creationDate }
    }

    /// No field was changed — applying it is a no-op the caller can skip entirely.
    public var isEmpty: Bool {
        permissions == nil && flags == nil && ownerID == nil && groupID == nil
            && accessDate == nil && modificationDate == nil && creationDate == nil
    }

    /// Owner and/or group is being changed — the pair a single `chown(2)` sets together.
    public var changesOwnership: Bool { ownerID != nil || groupID != nil }

    /// Access and/or modification time is being changed — the pair a single `utimes(2)` sets. Birth
    /// time is separate (``creationDate``) because `utimes` cannot set it.
    public var changesUtimes: Bool { accessDate != nil || modificationDate != nil }
}
