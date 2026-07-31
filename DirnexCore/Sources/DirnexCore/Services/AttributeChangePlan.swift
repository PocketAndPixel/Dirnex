import Foundation

/// The ordered sequence of syscalls that applies an ``AttributeDiff`` — computed as a pure value so
/// the ordering, which is where the bugs live and which no dialog screenshot can show, is pinned by
/// tests rather than trusted (PLAN.md §M14 Slice 3).
///
/// Two orderings matter, and both were found by probing rather than reasoned from the man pages:
///
/// - **Unlock → apply → relock.** `chmod`, `chown` and `utimes` all fail with `EPERM` while
///   `UF_IMMUTABLE` (Finder's "Locked") is set — and that `EPERM` is *indistinguishable* from the one
///   that genuinely needs root, so a panel that skipped this would send a locked-file edit down a
///   pointless privilege-escalation path (docs/NOTES.md). So if the item is immutable and anything
///   other than its flags is changing, the plan clears the immutable bit first and restores the
///   desired flags last.
/// - **`chown` before `chmod`.** `chown(2)` clears the set-uid and set-gid bits for an unprivileged
///   caller, so changing owner *after* mode would silently drop a set-uid the user just asked for.
///   Ownership therefore lands before permissions.
///
/// Two more steps exist purely to *undo a side effect the user did not ask for*, both measured in the
/// Slice 4 probe (2026-07-31) and both invisible without one — see ``preservedPermissions(...)`` and
/// ``preservedCreationDate(...)``. They are the same shape as the unlock/relock above: the diff is the
/// contract ("a field left alone is never written"), and a syscall that rewrites a neighbouring field
/// breaks it unless the plan puts it back.
///
/// The plan is deliberately about *order and content*, not execution: it names each step and the
/// value it writes. `AttributeApplier` runs it, choosing the `l*` variant per ``actsOnLink`` so a
/// symlink's own attributes change rather than its target's (Finder's Get Info acts on the link).
public struct AttributeChangePlan: Sendable, Equatable {
    /// One syscall's worth of change. `utimes` carries *both* times because it cannot leave one
    /// alone; `chown` carries an optional each because `(uid_t)-1` means "unchanged".
    public enum Step: Sendable, Equatable {
        /// `chown` / `lchown`. A `nil` means "leave this one" (`(uid_t)-1` at the syscall).
        case setOwnership(userID: UInt32?, groupID: UInt32?)
        /// `chmod` / `lchmod`.
        case setPermissions(POSIXPermissions)
        /// `utimes` / `lutimes` — both times, changed or carried from current.
        case setTimes(access: Date, modification: Date)
        /// `setattrlist(ATTR_CMN_CRTIME)` — the birth time `utimes` cannot touch.
        case setCreationDate(Date)
        /// `chflags` / `lchflags`. Emitted for a temporary unlock, a final relock, or an ordinary
        /// flags change — the value is always the whole target word.
        case setFlags(BSDFileFlags)
    }

    /// The item is a symlink and the change applies to the link itself, so the applier uses the `l*`
    /// syscall variants. Does not affect *which* steps run, only how each is executed.
    public let actsOnLink: Bool

    /// The steps, in the exact order they must run.
    public let steps: [Step]

    public init(diff: AttributeDiff, current: FileAttributes, actsOnLink: Bool) {
        self.actsOnLink = actsOnLink

        // A change to anything but the flags cannot proceed while an immutable bit is set.
        let hasNonFlagChange = diff.permissions != nil
            || diff.changesOwnership || diff.changesUtimes || diff.creationDate != nil
        let unlockNeeded = current.flags.blocksModification && hasNonFlagChange
        let unlockTarget = current.flags.subtracting([.userImmutable, .systemImmutable])

        var steps: [Step] = []
        if unlockNeeded { steps.append(.setFlags(unlockTarget)) }

        // Ownership before permissions, so a set-uid/gid bit set by the chmod survives the chown.
        if diff.changesOwnership {
            steps.append(.setOwnership(userID: diff.ownerID, groupID: diff.groupID))
        }
        // The user's own value always wins over a repair; the repair only fills a gap they left.
        let mode = diff.permissions ?? Self.preservedPermissions(diff: diff, current: current)
        if let mode {
            steps.append(.setPermissions(mode))
        }
        if diff.changesUtimes {
            steps.append(.setTimes(
                access: diff.accessDate ?? current.accessDate,
                modification: diff.modificationDate ?? current.modificationDate
            ))
        }
        let birth = diff.creationDate ?? Self.preservedCreationDate(diff: diff, current: current)
        if let birth {
            steps.append(.setCreationDate(birth))
        }

        // Final flags: whatever the diff asked for (or the current word, to relock). Emit only when it
        // differs from what is on disk *now* — after the optional unlock — so an "unlock and leave it
        // unlocked" edit does not write the same word twice.
        let finalFlags = diff.flags ?? current.flags
        let flagsOnDiskNow = unlockNeeded ? unlockTarget : current.flags
        if finalFlags != flagsOnDiskNow {
            steps.append(.setFlags(finalFlags))
        }

        self.steps = steps
    }

    /// Nothing to do.
    public var isEmpty: Bool { steps.isEmpty }

    // MARK: - Repairing what a syscall changes behind the user's back

    /// The mode to re-write after an ownership change that would otherwise drop a special bit — or
    /// `nil` when the user is already setting the mode themselves, or there is nothing to lose.
    ///
    /// **`chown(2)` clears set-uid *and* set-gid for an unprivileged caller, and a plain `chgrp` is a
    /// `chown` too.** Measured 2026-07-31: a `0o6755` file handed from group `staff` to group `admin`
    /// came back `0o755`, with no mode change requested and nothing to say so. The chown-before-chmod
    /// ordering above already covers the case where the user *is* changing the mode; this covers the
    /// one where they changed only the group, which the ordering alone cannot help with because there
    /// is no chmod in the plan to be ordered.
    private static func preservedPermissions(
        diff: AttributeDiff,
        current: FileAttributes
    ) -> POSIXPermissions? {
        guard diff.changesOwnership else { return nil }
        let special = current.permissions.setUserID || current.permissions.setGroupID
        return special ? current.permissions : nil
    }

    /// The birth time to re-write after a modification-time change that would otherwise drag it
    /// backwards — or `nil` when the user is setting the creation date themselves, or nothing moves.
    ///
    /// **Setting `st_mtime` earlier than `st_birthtime` pulls the birth time back to match.** Measured
    /// 2026-07-31 on APFS, files and directories alike: a file born today, given an mtime of 2001,
    /// reported a *creation* date of 2001 afterwards. It is `mtime` alone that does this — an atime in
    /// the same past left the birth time untouched — and re-setting the birth time afterwards repairs
    /// it exactly, which is why this is a step and not a refusal.
    ///
    /// Order matters and is already right: ``Step/setTimes(access:modification:)`` precedes
    /// ``Step/setCreationDate(_:)``, and `setattrlist(ATTR_CMN_CRTIME)` was measured *not* to disturb
    /// either of the other two times, so the repair cannot undo the edit that provoked it.
    private static func preservedCreationDate(
        diff: AttributeDiff,
        current: FileAttributes
    ) -> Date? {
        guard let modification = diff.modificationDate else { return nil }
        return modification < current.creationDate ? current.creationDate : nil
    }
}
