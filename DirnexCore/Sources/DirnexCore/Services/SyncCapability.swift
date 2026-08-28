import Foundation

/// What a pair of sync sides permits, once a side need no longer be on this disk (PLAN.md §M25
/// Slice 5c).
///
/// Two rules, both of them the same shape as ``SyncComparison/available(between:and:)`` and kept
/// beside each other for the same reason: a directory sync now spans two locations that can differ
/// in what they carry, what they accept and what a delete there *means*, and each of those has to be
/// answered before the sheet offers a control rather than after the queue fails.

public extension SyncDirection {
    /// The reconciliations that can actually be run between these two sides.
    ///
    /// A direction is a promise to change its destination, so it is available exactly when that
    /// destination accepts changes: a mirror leftward needs a writable left side, rightward a
    /// writable right one, and the bidirectional union needs both. A read-only S3 bucket as a source
    /// is an ordinary and useful thing to mirror *from*, so this withdraws a direction rather than
    /// the whole sheet.
    ///
    /// Asked up front, because the alternative is the failure ``VFSBackendID/acceptsUploads``' own
    /// doc comment was written about: every capability-shaped gate says yes, the run starts, and the
    /// copies fail *inside the queue* one at a time instead of the control saying up front that this
    /// side cannot receive files.
    static func available(
        leftAcceptsChanges: Bool,
        rightAcceptsChanges: Bool
    ) -> [SyncDirection] {
        var available: [SyncDirection] = []
        if rightAcceptsChanges { available.append(.leftToRight) }
        if leftAcceptsChanges, rightAcceptsChanges { available.append(.bidirectional) }
        if leftAcceptsChanges { available.append(.rightToLeft) }
        return available
    }
}

/// What a sync's deletions will actually do, split by the strategy each path's own backend offers.
///
/// The sentence a sync shows before it runs used to be one sentence — *"Synchronizing will move N
/// items to the Trash. You can restore them from the Trash later."* — which was true while both
/// sides were on this disk and became a straight lie the moment one of them was a server: no remote
/// backend implements `trashItem`, so ``VFSCapabilities/deleteStrategy`` degrades to
/// ``DeleteStrategy/permanent`` everywhere remote and those files are gone. Promising a Trash that
/// does not exist is exactly the failure this milestone is about, and it is the worst-placed one
/// available, because it is the sentence somebody reads *while deciding*.
///
/// So the counts are split before anything is asked, and a mixed run — a local pane against a server,
/// which is the ordinary shape — says both halves. The split also decides how the deletes run:
/// ``DeletePass`` takes one `permanent` flag for a whole batch, so a mixed set is two passes rather
/// than one guess.
///
/// ``unsupported`` is the third bucket rather than being folded into either: a read-only side cannot
/// delete at all, and an item that will not be touched must not be counted in a sentence that says
/// it will. It is normally unreachable — ``SyncDirection/available(leftAcceptsChanges:rightAcceptsChanges:)``
/// withdraws the direction that would prune such a side — and stays here because a per-row override
/// can still name one.
public struct SyncDeletePlan: Sendable, Equatable {
    /// Paths whose backend keeps a Trash: recoverable, and undoable through the journal.
    public let toTrash: [VFSPath]
    /// Paths on a backend that can delete but has no Trash — every remote account, and a local
    /// volume that keeps none. Irreversible.
    public let permanent: [VFSPath]
    /// Paths on a side that cannot delete at all. Nothing will happen to these.
    public let unsupported: [VFSPath]

    public init(toTrash: [VFSPath] = [], permanent: [VFSPath] = [], unsupported: [VFSPath] = []) {
        self.toTrash = toTrash
        self.permanent = permanent
        self.unsupported = unsupported
    }

    /// Split `paths` by what deleting each one would do, preserving order within each bucket.
    ///
    /// - Parameter strategy: the delete path that item's own backend offers, which the caller reads
    ///   from `capabilities(for:)` — per **path**, never per pane, since the two sides of a sync are
    ///   two backends and a row names one of them.
    public init(paths: [VFSPath], strategy: (VFSPath) -> DeleteStrategy) {
        var toTrash: [VFSPath] = []
        var permanent: [VFSPath] = []
        var unsupported: [VFSPath] = []
        for path in paths {
            switch strategy(path) {
            case .trash: toTrash.append(path)
            case .permanent: permanent.append(path)
            case .unsupported: unsupported.append(path)
            }
        }
        self.init(toTrash: toTrash, permanent: permanent, unsupported: unsupported)
    }

    /// Whether anything at all will be deleted. `unsupported` is deliberately not counted: those
    /// items are named, not acted on.
    public var isEmpty: Bool { toTrash.isEmpty && permanent.isEmpty }

    /// How many items will actually be deleted, by either route.
    public var count: Int { toTrash.count + permanent.count }
}
