import DirnexCore
import Foundation

/// What the copy and move progress dialog shows, read from the last known snapshot of each job it
/// follows (PLAN.md §M41).
///
/// A pure value so the rules can be tested without a window. The dialog keeps the last snapshot it
/// saw of each job, rather than only the current queue snapshot, because the queue drops finished
/// jobs once it drains: the dialog must still know they finished. A keeping-folders copy across
/// tree levels is one job per folder, so everything here is a sum over jobs.
struct TransferDialogState: Equatable {
    enum Phase: Equatable {
        /// Queued, or about to be, with nothing measured yet.
        case preparing
        /// Queued behind other work. A job reads `.waiting` for an instant between being queued and
        /// starting, so this is only said while some other job is in fact running.
        case waiting
        case running
        /// Every job still to finish is paused, by its own Pause or by the queue bar's, or is waiting
        /// in a queue the bar has paused.
        case paused
        /// Every job has finished or been canceled, and no more are coming.
        case done
    }

    var phase: Phase
    var totalBytes: Int64 = 0
    var completedBytes: Int64 = 0
    var totalFiles = 0
    var completedFiles = 0
    /// The file being written now, at any depth.
    var currentFile: VFSPath?
    var currentFileFraction: Double = 0
    /// The top-level item the copy is on, for when no file is named (a clone takes a folder whole).
    var currentItem: VFSPath?
    /// Every job still to finish is paused on its own (``JobSnapshot/isHeld``), so the dialog's Pause
    /// reads Resume. A job paused only by the queue bar is resumed from there.
    var isHeld = false

    /// How far the whole transfer is, in `0...1`: by bytes, else by files.
    var fraction: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        if totalFiles > 0 { return min(1, Double(completedFiles) / Double(totalFiles)) }
        return phase == .done ? 1 : 0
    }

    /// What the rest of the queue is doing, which decides how a waiting job reads.
    struct Queue: Equatable {
        /// Some job this transfer does not own is running or paused.
        var othersActive = false
        /// The queue bar has paused the whole queue.
        var isPaused = false
    }

    /// The state of `jobs`, the last known snapshot of each tracked job.
    ///
    /// - Parameters:
    ///   - tracked: how many jobs the transfer has queued so far; one not yet in `jobs` has not been
    ///     seen in a snapshot, and counts as preparing.
    ///   - isSubmitting: whether more jobs may still come (a keeping-folders copy makes its folders
    ///     first), in which case the transfer is not done whatever its jobs say.
    static func read(
        _ jobs: [JobSnapshot],
        tracked: Int,
        isSubmitting: Bool,
        queue: Queue = Queue()
    ) -> TransferDialogState {
        var state = TransferDialogState(phase: .preparing)
        for job in jobs {
            state.totalBytes += job.progress?.totalBytes ?? 0
            state.completedBytes += job.report?.completedBytes ?? job.progress?.completedBytes ?? 0
            state.totalFiles += job.progress?.files?.total ?? 0
            state.completedFiles += job.progress?.files?.completed ?? 0
        }
        let open = jobs.filter { !Self.isTerminal($0.status) }
        let current = open.first { $0.status == .running } ?? open.first { $0.status == .paused }
        state.currentItem = current?.progress?.currentItem
        if let files = current?.progress?.files, let file = files.current {
            state.currentFile = file
            state.currentFileFraction = files.currentFraction
        }
        state.isHeld = !open.isEmpty && open.allSatisfy(\.isHeld)
        let unseen = tracked - jobs.count
        state.phase = phase(of: open, isComplete: unseen <= 0 && !isSubmitting, queue: queue)
        return state
    }

    private static func phase(of open: [JobSnapshot], isComplete: Bool, queue: Queue) -> Phase {
        if open.contains(where: { $0.status == .running }) { return .running }
        if open.contains(where: { $0.status == .paused }) { return .paused }
        if open.contains(where: { $0.status == .waiting }) {
            if queue.isPaused { return .paused }
            return queue.othersActive ? .waiting : .preparing
        }
        return open.isEmpty && isComplete ? .done : .preparing
    }

    private static func isTerminal(_ status: JobStatus) -> Bool {
        status == .finished || status == .cancelled
    }
}
