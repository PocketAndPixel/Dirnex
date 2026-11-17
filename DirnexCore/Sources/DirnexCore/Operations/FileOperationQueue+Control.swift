import Foundation

/// Pausing, resuming and canceling queued jobs: the whole queue from the queue bar, or one job from
/// the copy and move progress dialog (PLAN.md §M41).
///
/// Split out of `FileOperationQueue` by concept when the per-job pause arrived, which would have
/// taken that file past the file-length ceiling (docs/NOTES.md ▸ Lint ceilings and file splitting).
///
/// The two pauses are kept apart rather than one being built from the other. The queue-wide pause
/// stops anything new from starting and parks every running job. A job paused on its own is in
/// `heldJobs`: a running one parks at its next checkpoint exactly as under the queue-wide pause, and
/// a waiting one is held back, so it does not start when its turn comes. Either pause leaves the
/// other as it found it, so pausing one copy in its dialog and then pausing and resuming the whole
/// queue from the bar leaves that copy paused.
extension FileOperationQueue {
    // MARK: - The whole queue

    /// Stop starting new jobs and park the ones already running. A parked transfer resumes
    /// exactly where it left off; nothing is thrown away.
    public func pause() {
        guard !isPausedFlag else { return }
        isPausedFlag = true
        for id in runningIDs {
            controls[id]?.setPaused(true)
            if var job = jobs[id], job.status == .running {
                job.status = .paused
                jobs[id] = job
            }
        }
        publish()
    }

    /// Undo `pause()`: start what may start and release the parked jobs, except a job paused on its
    /// own by `pause(_:)`, which stays paused until `resume(_:)`.
    public func resume() {
        guard isPausedFlag else { return }
        isPausedFlag = false
        for id in runningIDs where !heldJobs.contains(id) {
            controls[id]?.setPaused(false)
            if var job = jobs[id], job.status == .paused {
                job.status = .running
                jobs[id] = job
            }
        }
        publish()
        pump()
    }

    // MARK: - One job

    /// Pause one job, leaving the rest of the queue running: the progress dialog's Pause, and what
    /// its Cancel does while it asks whether to stop.
    ///
    /// A running job parks at its next checkpoint and reads `.paused`. A waiting job reads `.paused`
    /// too and is held back: the scheduler starts only `.waiting` jobs, so it does not start when its
    /// turn comes, and a job behind it on the same volumes may start first. A finished or canceled
    /// job, or one already paused this way, is left alone.
    public func pause(_ id: OperationJobID) {
        guard var job = jobs[id], job.status != .finished, job.status != .cancelled,
              heldJobs.insert(id).inserted else { return }
        if runningIDs.contains(id) { controls[id]?.setPaused(true) }
        job.status = .paused
        jobs[id] = job
        publish()
    }

    /// Undo `pause(_:)` for one job. A job that had started carries on, unless the whole queue is
    /// paused, in which case it stays parked until `resume()`. One that had not started goes back
    /// to waiting its turn.
    public func resume(_ id: OperationJobID) {
        guard heldJobs.remove(id) != nil, var job = jobs[id] else { return }
        if !runningIDs.contains(id) {
            job.status = .waiting
        } else if !isPausedFlag {
            controls[id]?.setPaused(false)
            job.status = .running
        }
        jobs[id] = job
        publish()
        pump()
    }

    // MARK: - Cancel

    /// Cancel one job. A job that has not started (waiting, or paused before it started) is dropped
    /// as it is; a started one, paused or not, is told to unwind — the engine cleans up any
    /// half-written file and reports back with `wasCancelled`, at which point `complete` marks it
    /// canceled.
    public func cancel(_ id: OperationJobID) {
        guard var job = jobs[id], job.status != .finished, job.status != .cancelled else { return }
        guard !runningIDs.contains(id) else {
            controls[id]?.cancel() // completion arrives via the engine's canceled report
            return
        }
        heldJobs.remove(id)
        job.status = .cancelled
        jobs[id] = job
        publish()
        checkIdle()
    }

    public func cancelAll() {
        for id in order { cancel(id) }
    }
}

// MARK: - Job control

/// The shared cancel/pause handle between the actor and a job's detached engine run.
///
/// The engine polls one closure — its `isCancelled` — between chunks and items. We route
/// that through `checkpoint`, which does double duty: it reports cancellation, and while
/// the job is paused it *blocks the copy thread* on a condition variable until the job
/// is resumed or canceled. That gives a real mid-flight pause without the engine needing
/// to know the queue exists. A plain lock-guarded flag pair, safe to touch from the actor
/// and the copy thread alike.
///
/// One flag serves both pauses: the actor works out whether a job should be parked (the queue is
/// paused, or the job is held) and sets it accordingly.
final class JobControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var canceled = false
    private var paused = false

    func cancel() {
        condition.lock()
        canceled = true
        condition.broadcast() // wake a parked checkpoint so it can unwind
        condition.unlock()
    }

    func setPaused(_ value: Bool) {
        condition.lock()
        paused = value
        if !value { condition.broadcast() } // resume: release any parked checkpoint
        condition.unlock()
    }

    /// Called by the engine between chunks/items. Blocks while the job is paused; returns
    /// `true` once it should abort, so the engine throws `CancellationError` and cleans up.
    func checkpoint() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused, !canceled { condition.wait() }
        return canceled
    }
}
