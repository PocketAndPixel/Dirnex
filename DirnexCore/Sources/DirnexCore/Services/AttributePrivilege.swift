import Foundation

/// Who is making the change: the effective user id and the groups they belong to. Everything
/// ``AttributePrivilege`` needs to know about the caller, injected so the table is a pure function
/// and testable without being root or joining a group.
public struct UserContext: Sendable, Equatable {
    public let userID: UInt32
    /// The caller's group memberships (`getgid()` plus `getgroups()`), which decide whether a `chgrp`
    /// is allowed unprivileged.
    public let groupIDs: Set<UInt32>

    public init(userID: UInt32, groupIDs: Set<UInt32>) {
        self.userID = userID
        self.groupIDs = groupIDs
    }

    public var isSuperUser: Bool { userID == 0 }

    /// The identity of the running process — effective uid and the full supplementary group list.
    /// The app's entry point into the table; the core logic never calls it, so the table stays pure.
    public static func current() -> UserContext {
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let count = getgroups(Int32(groups.count), &groups)
        var ids = Set<UInt32>([getgid()])
        if count > 0 { ids.formUnion(groups.prefix(Int(count)).map { UInt32($0) }) }
        return UserContext(userID: getuid(), groupIDs: ids)
    }
}

/// Given an ``AttributeDiff`` and who is applying it, does it need root — and if so, exactly why
/// (PLAN.md §M14 Slice 3). A pure table, straight from the M14 probe matrix (2026-07-29), and the
/// thing that decides whether Slice 5's escalation is even reachable.
///
/// The design rests on one finding: for a file the user **owns**, almost everything an attributes
/// panel touches is unprivileged — mode bits, the `UF_*` flags, times, and a `chgrp` to a group they
/// are in. Root is needed for exactly three narrow cases, so escalation is offered only where a
/// reason below is present, never as a blanket "try again as admin" that would train the user to
/// approve an authentication prompt they almost never need.
public enum AttributePrivilege {
    /// Why a particular change cannot be made unprivileged.
    public enum Reason: Sendable, Equatable, Hashable {
        /// The whole diff needs root because the item belongs to another user. Supersedes the rest —
        /// nothing about someone else's file is editable unprivileged.
        case notOwner
        /// One or more `SF_*` (super-user) flag bits are being changed. Carries just those bits.
        case systemFlags(BSDFileFlags)
        /// Ownership is being handed to another user — a `chown` an owner cannot do to their own file.
        case changeOwner
        /// The file is being moved to a group the caller does not belong to.
        case changeToForeignGroup(groupID: UInt32)
    }

    /// The reasons `diff` needs root, given the item's current state and the caller. Empty means it
    /// applies unprivileged.
    public static func reasons(
        for diff: AttributeDiff,
        current: FileAttributes,
        actor: UserContext
    ) -> [Reason] {
        guard !diff.isEmpty, !actor.isSuperUser else { return [] }
        // Someone else's file: the whole edit is root's, and no per-field reason adds anything.
        guard current.ownerID == actor.userID else { return [.notOwner] }

        var reasons: [Reason] = []
        var systemBits = BSDFileFlags()
        // Explicitly changing an SF_* bit needs root.
        if let desired = diff.flags {
            systemBits.formUnion(desired.symmetricDifference(current.flags).superUserBits)
        }
        // So does an *implicit* one: a system-immutable file must have that bit cleared before any
        // non-flag change can apply (`chmod` on it is EPERM), and clearing SF_IMMUTABLE is root's —
        // unlike UF_IMMUTABLE, which the owner clears unprivileged. Without this, an owner editing the
        // mode of an SF_IMMUTABLE file would be told "no root needed" and then hit the bare EPERM this
        // whole design exists to avoid.
        let hasNonFlagChange = diff.permissions != nil
            || diff.changesOwnership || diff.changesUtimes || diff.creationDate != nil
        if hasNonFlagChange {
            systemBits.formUnion(current.flags.intersection(.systemImmutable))
        }
        if !systemBits.isEmpty { reasons.append(.systemFlags(systemBits)) }

        if diff.ownerID != nil { reasons.append(.changeOwner) }
        if let groupID = diff.groupID, !actor.groupIDs.contains(groupID) {
            reasons.append(.changeToForeignGroup(groupID: groupID))
        }
        return reasons
    }

    /// Whether `diff` needs root at all — `reasons(...)` non-empty.
    public static func needsRoot(
        for diff: AttributeDiff,
        current: FileAttributes,
        actor: UserContext
    ) -> Bool {
        !reasons(for: diff, current: current, actor: actor).isEmpty
    }
}
