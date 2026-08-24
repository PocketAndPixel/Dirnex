import Foundation

/// Whether a delete failure is really the volume saying it keeps no Trash.
///
/// Its own type because this is the decision that routes a failure away from the errno alert, it is
/// the half a test can drive with no window, and spelling it inline at a call site would leave the
/// rule where nothing can assert it.
///
/// The predicate is narrow on purpose. `VFSError.unsupported(.trash)` reaches a delete from exactly
/// two places — the protocol default, for a backend with no `trashItem` at all, and
/// ``LocalBackend/trashFailure(_:path:)``, for a volume that refused one — and a caller can only
/// have *attempted* a trash on a backend whose `deleteStrategy` was `.trash`, so reaching this at
/// all means the second. Every other failure is a real one and keeps its own alert: a permission
/// problem is not answered by offering to delete the file for good.
///
/// Lives in the core rather than beside the alert it feeds because three flows now ask it — F8, the
/// F6 move into an archive, and a directory sync's deletes — and one rule spelled three times is
/// this project's most repeated bug.
public enum TrashRefusal {
    public static func isVolumeWithoutTrash(_ error: any Error) -> Bool {
        guard let error = error as? VFSError, case .unsupported(.trash) = error else { return false }
        return true
    }
}

/// Delete a batch of paths through a backend, collecting what happened to each one instead of
/// stopping at the first problem.
///
/// The one home for a loop three flows were each spelling for themselves, two of them with a `try?`
/// that swallowed every failure — so on a volume that keeps no Trash an F6 move into an archive
/// silently became a copy, and a directory sync reported deletions it had not made (reported
/// 2026-08-25). A `try?` cannot tell the three outcomes below apart, and they need opposite
/// answers.
///
/// Synchronous and blocking, like every other byte-touching engine here: callers hand it to
/// `BlockingWork.run` rather than a `Task.detached` (docs/NOTES.md ▸ Swift 6 and concurrency).
public enum DeletePass {
    /// One trashed item's before/after locations, captured so Cmd+Z can restore it from the Trash
    /// (PLAN.md §M2 "delete-to-Trash restore").
    public struct Restoration: Sendable, Equatable {
        public let original: VFSPath
        public let trashed: VFSPath

        public init(original: VFSPath, trashed: VFSPath) {
            self.original = original
            self.trashed = trashed
        }
    }

    /// What a delete pass produced.
    ///
    /// ``refused`` is kept apart from ``failures`` because it is not one: those items are
    /// **untouched** on a volume that keeps no Trash, so what they need is the permanent delete
    /// offered instead — not an alert with a number in it (``TrashRefusal``). Nothing has moved
    /// when they are reported, which is what lets a caller raise a genuine question rather than a
    /// report of something already done.
    ///
    /// A `permanent` pass can never fill it: `removeItem` does not consult a Trash, so
    /// `.unsupported(.trash)` cannot arise there. That is what makes "offer the permanent delete"
    /// terminate — the offer's own re-run has no refusals of its own to re-offer.
    public struct Outcome: Sendable, Equatable {
        public let failures: [OperationItemFailure]
        public let restorations: [Restoration]
        public let refused: [VFSPath]

        public init(
            failures: [OperationItemFailure] = [],
            restorations: [Restoration] = [],
            refused: [VFSPath] = []
        ) {
            self.failures = failures
            self.restorations = restorations
            self.refused = refused
        }
    }

    /// Delete every path in `paths`, permanently or to the Trash, and report each outcome.
    ///
    /// Never throws: one item's failure must not abandon the rest of a batch, which is the whole
    /// reason a sync or a multi-selection delete can report per item at all.
    public static func run(
        _ paths: [VFSPath],
        using backend: any VFSBackend,
        permanent: Bool
    ) -> Outcome {
        var failures: [OperationItemFailure] = []
        var restorations: [Restoration] = []
        var refused: [VFSPath] = []
        for path in paths {
            do {
                if permanent {
                    try backend.removeItem(at: path)
                } else if let trashed = try backend.trashItem(at: path) {
                    restorations.append(Restoration(original: path, trashed: trashed))
                }
            } catch let error where TrashRefusal.isVolumeWithoutTrash(error) {
                refused.append(path)
            } catch let error as VFSError {
                failures.append(OperationItemFailure(path: path, error: error))
            } catch {
                // A backend that raised something outside the vocabulary: still an item the caller
                // must be told about, since the alternative is the silence this type exists to end.
                failures.append(OperationItemFailure(path: path, error: .io(path: path, code: 0)))
            }
        }
        return Outcome(failures: failures, restorations: restorations, refused: refused)
    }
}
