import Foundation

/// The part of an undo or a redo that only an administrator can make, taken out of the record to run
/// as root before the rest (PLAN.md §M40 Slice 5).
///
/// Until this slice the journal refused such a step by name
/// (``VFSUnsupportedReason/attributeRestoreNeedsAdministrator(name:)``): a change made as
/// administrator, to someone else's file, could be made in one gesture and never taken back. The
/// app now asks first, in the administrator dialog the change itself was made through, and this is
/// what it asks about.
///
/// **What needs root is measured, never remembered.** A record says nothing about how its change was
/// made, and the answer moves with the disk: the same step needs root on a file root owns now and not
/// after `chown` gave it back. So each local attribute step is measured against its item as it is,
/// through ``LocalAttributeRestore``, the executor's own measure. A step this leaves in
/// ``remainder`` is therefore one the executor will not refuse for root, as long as the item does not
/// change in between.
///
/// **One item per path.** A record can hold an item's attributes and its list as two steps. Both go
/// to root together, as one ``EscalatedAttributeBatch/Item``, because the list's unlock and relock
/// have to be planned against the flags the same command leaves, which is what
/// ``AttributeChangePlan`` does for the two halves of one change. Items keep the order the record
/// names them in; every other step keeps its place in ``remainder``.
///
/// Redo is the same question asked of the inverted record, so it needs nothing of its own.
public struct EscalatedUndo: Sendable, Equatable {
    /// The items whose steps need root, each planned against the item as it is now.
    public let batch: EscalatedAttributeBatch
    /// The record without those items' steps: what runs unprivileged once the batch has run.
    public let remainder: UndoRecord

    /// Measure every local attribute step of `record` for `actor`. `nil` when none needs root, which
    /// is every record holding no such step, and every one whose items are all the actor's to change.
    ///
    /// An item that cannot be read stays in ``remainder``, where the executor reports it as it
    /// always has.
    public init?(reverting record: UndoRecord, actor: UserContext) {
        var order: [VFSPath] = []
        var requests: [VFSPath: Request] = [:]
        for step in record.steps {
            guard let path = step.localAttributePath else { continue }
            if requests[path] == nil {
                order.append(path)
                requests[path] = Request(actsOnLink: step.actsOnLink)
            }
            requests[path]?.add(step)
        }

        var items: [EscalatedAttributeBatch.Item] = []
        var escalated: Set<VFSPath> = []
        for path in order {
            guard let request = requests[path],
                  let restore = try? LocalAttributeRestore(
                      path: path,
                      actsOnLink: request.actsOnLink,
                      diff: request.diff,
                      accessControlList: request.list
                  ),
                  !restore.isEmpty,
                  restore.needsRoot(for: actor)
            else { continue }
            items.append(restore.batchItem)
            escalated.insert(path)
        }
        guard !items.isEmpty else { return nil }

        batch = EscalatedAttributeBatch(items: items)
        remainder = UndoRecord(
            id: record.id,
            label: record.label,
            date: record.date,
            steps: record.steps.filter { step in
                guard let path = step.localAttributePath else { return true }
                return !escalated.contains(path)
            },
            nonReversibleCount: record.nonReversibleCount
        )
    }

    /// What a record's steps ask of one item.
    private struct Request {
        let actsOnLink: Bool
        var diff = AttributeDiff()
        var list: AccessControlList?

        mutating func add(_ step: UndoStep) {
            switch step {
            case let .restoreAttributes(_, _, apply, _):
                diff = diff.overlaid(by: apply)
            case let .restoreAccessControlList(_, _, apply, _):
                list = apply
            default:
                break
            }
        }
    }
}

public extension UndoRecord {
    /// Whether any step changes the attributes of an item on this Mac: the only steps that can need
    /// root, so a record without one is reverted without asking ``EscalatedUndo`` anything.
    var changesLocalAttributes: Bool {
        steps.contains { $0.localAttributePath != nil }
    }
}

extension UndoStep {
    /// The item a local attribute step changes, `nil` for every other step.
    var localAttributePath: VFSPath? {
        switch self {
        case let .restoreAttributes(path, _, _, _), let .restoreAccessControlList(path, _, _, _):
            path
        default:
            nil
        }
    }

    /// Whether a local attribute step acts on a symlink itself; `false` for every other step.
    fileprivate var actsOnLink: Bool {
        switch self {
        case let .restoreAttributes(_, actsOnLink, _, _),
             let .restoreAccessControlList(_, actsOnLink, _, _):
            actsOnLink
        default:
            false
        }
    }
}
