import DirnexCore
import Foundation

/// A copy or move that F5 or F6 is about to start, described for the dialog that asks first
/// (PLAN.md §M41).
struct TransferSummary {
    let kind: FileOperation.Kind
    /// The marked items as they will land, before any are queued.
    let sources: [FileEntry]
    /// The folder they go into: the other pane's, which the dialog's field opens with.
    let destination: VFSPath
    /// Why the items cannot go into a folder typed in place of ``destination``, as a sentence for
    /// under the field, or `nil` when they can (2026-11-19). Asked with the dialog still up, so a
    /// refusal leaves the field to fix rather than ending the dialog.
    var refusal: @MainActor (VFSPath) -> String? = { _ in nil }
}

/// How the jobs of one copy or move reach the dialog that follows them: by id, **before** each is
/// queued (PLAN.md §M41).
///
/// Before, not after, because the queue forgets a job once it drains, and a clone finishes in the
/// turn it starts. An id the dialog learned from `enqueue`'s answer could arrive after the only
/// snapshot that ever showed the job, and the dialog would wait for it forever (docs/NOTES.md ▸
/// Swift 6 and concurrency, the handle that only exists after the work has started). So the pane asks
/// this for each job's id, the dialog hears of it then, and the queue is handed the same id.
///
/// `finish()` says no more jobs are coming, which is what lets the dialog close once the ones it has
/// are done, and close at once when a transfer queued nothing at all (a keeping-folders copy whose
/// folders could not be made).
@MainActor
final class TransferTracker {
    /// For a transfer nobody follows: no dialog, as when Settings turns the dialogs off, for a script,
    /// and in a test's stub host.
    static var untracked: TransferTracker {
        TransferTracker(onTrack: { _ in }, onFinish: {})
    }

    private let onTrack: (OperationJobID) -> Void
    private let onFinish: () -> Void
    private var isFinished = false

    init(onTrack: @escaping (OperationJobID) -> Void, onFinish: @escaping () -> Void) {
        self.onTrack = onTrack
        self.onFinish = onFinish
    }

    /// The id for the next job, already known to whoever follows the transfer.
    func nextID() -> OperationJobID {
        let id = OperationJobID()
        onTrack(id)
        return id
    }

    /// Every job is queued, or none will be. Only the first call counts.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        onFinish()
    }
}
