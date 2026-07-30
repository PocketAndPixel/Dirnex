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
        if let permissions = diff.permissions {
            steps.append(.setPermissions(permissions))
        }
        if diff.changesUtimes {
            steps.append(.setTimes(
                access: diff.accessDate ?? current.accessDate,
                modification: diff.modificationDate ?? current.modificationDate
            ))
        }
        if let creationDate = diff.creationDate {
            steps.append(.setCreationDate(creationDate))
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
}
