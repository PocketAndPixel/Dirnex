import Foundation

// MARK: - Job

/// What a queued **recursive** attributes apply is being asked to do (PLAN.md §M14 Slice 4).
///
/// The flat case — one item, or a marked set — commits straight from the sheet, because it is a
/// handful of syscalls and finishes before the sheet closes. Recursion is a different animal: it is
/// the one shape in this feature that can wreck a tree, it can run over a hundred thousand items,
/// and so it belongs on `FileOperationQueue` with a determinate bar and a cancel button, exactly
/// like a copy.
///
/// What it carries is the *patch*, not a value, for the reason ``AttributePatch`` exists: the items
/// inside a folder do not start from the same attributes, and a bit the user never touched must stay
/// whatever each item already had. Every enclosed item is therefore diffed against its own current
/// state and run through the tested ``AttributeChangePlan`` / ``FileAttributeIO`` path — the
/// recursion adds a walk and a queue, and changes nothing about how one item is written.
public struct AttributeApplyJob: Sendable, Equatable {
    /// The mode/flags/group/date change to force on every item in scope.
    public var patch: AttributePatch

    /// The access-control list to write to every item in scope, or `nil` to leave each item's own
    /// alone — the diff-based contract applied to the ACL half: it propagates only when the user
    /// actually edited it.
    ///
    /// It is **replaced**, not merged. An ACL is an ordered list whose order is meaning, so there is
    /// no sound way to fold one list into another; "apply this to everything inside" is the only
    /// description that is always right, and it is what the sheet says. Each item receives the list
    /// through ``AccessControlList/adjusted(for:)``, which is what keeps a directory's
    /// `delete_child` and inheritance flags off the files underneath it.
    public var accessControlList: AccessControlList?

    /// Which enclosed items are in scope. The roots are always changed (``AttributeApplyScope
    /// /rootsAlwaysApply``).
    public var target: AttributeApplyScope.Target

    /// How many changed items the run will journal for undo, at most.
    ///
    /// A cap rather than a hope, and the number comes from a measurement. An ``UndoStep
    /// /restoreAttributes`` encodes to a dead-constant **246 bytes** (probed 2026-08-01 over 1k…200k
    /// steps), and the journal is JSON in `UserDefaults` that is re-encoded on *every* later
    /// operation and every undo — so the cost is not the one write, it is the tax on everything
    /// afterwards: 10k steps is 2.3 MB and 60 ms, 50k is 11.7 MB and 280 ms, 200k is 47 MB and
    /// **1.1 s**. The apply itself is 17 µs an item, so it is only ever the journal that cannot
    /// scale.
    ///
    /// A run that would exceed the cap journals **nothing at all** rather than the first N items:
    /// undo is all-or-nothing here, because reverting an arbitrary slice of a tree leaves it in a
    /// state the user cannot reason about. The sheet counts the tree and says so before it starts,
    /// so this is never a surprise discovered afterwards.
    public var journalLimit: Int

    /// The measured default (see ``journalLimit``): 10 000 items ≈ 2.3 MB and 60 ms of encoding.
    public static let defaultJournalLimit = 10_000

    public init(
        patch: AttributePatch,
        accessControlList: AccessControlList? = nil,
        target: AttributeApplyScope.Target = .everything,
        journalLimit: Int = AttributeApplyJob.defaultJournalLimit
    ) {
        self.patch = patch
        self.accessControlList = accessControlList
        self.target = target
        self.journalLimit = journalLimit
    }

    /// Nothing is forced and no ACL is being written, so the run has nothing to do.
    public var isEmpty: Bool { patch.isEmpty && accessControlList == nil }
}

// MARK: - Outcome

/// What a finished recursive apply did, carried home on ``OperationReport/attributeApply``.
///
/// ``changed`` is the undo material and ``changedCount`` is the truth about the run, and they are
/// separate on purpose: over the journal limit the first is empty while the second is large, which
/// is precisely the state the completion sheet has to be able to describe.
public struct AttributeApplyOutcome: Sendable, Equatable {
    /// Per-item before/after for every item that actually changed — the input to
    /// ``UndoRecord/attributeBatchChange(_:date:)``. **Empty when ``isUndoable`` is `false`.**
    public let changed: [UndoRecord.AttributeBatchEntry]

    /// How many items actually changed, whether or not they were journaled.
    public let changedCount: Int

    /// Items the walk visited and left alone — already matching the patch, or filtered out by the
    /// target. Reported because "5 of 4 000 changed" is the answer to "did that do what I meant",
    /// and silence about the other 3 995 is not.
    public let visitedCount: Int

    /// Whether the run stayed inside ``AttributeApplyJob/journalLimit`` and can be reversed.
    public let isUndoable: Bool

    public init(
        changed: [UndoRecord.AttributeBatchEntry],
        changedCount: Int,
        visitedCount: Int,
        isUndoable: Bool
    ) {
        self.changed = changed
        self.changedCount = changedCount
        self.visitedCount = visitedCount
        self.isUndoable = isUndoable
    }
}
