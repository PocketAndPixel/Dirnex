import Foundation

/// Total Commander's background operation queue (PLAN.md §2 "OperationQueue actor:
/// serial-per-volume scheduling, pause/resume, ETA"), the scheduler that sits above the
/// single-shot `CopyEngine`.
///
/// Named `FileOperationQueue` rather than the plan's bare "OperationQueue" only to avoid
/// shadowing `Foundation.OperationQueue`; the role is the plan's.
///
/// What it buys over calling `CopyEngine.run` directly:
/// - **Volume-aware scheduling.** Jobs that touch a shared physical volume run one at a
///   time (two copies hammering the same disk head are slower than one), while jobs on
///   independent volumes run concurrently. "Which volume" comes from
///   `VFSBackend.volumeIdentifier(for:)`; a backend that can't tell volumes apart has all
///   its jobs serialized, which is the safe default.
/// - **Pause / resume.** Pausing stops new jobs from starting *and* parks the transfers
///   already running — the engine polls the job's cancel hook between chunks, and while
///   paused that hook blocks the copy thread until resume (or cancel).
/// - **Cancel** a single job or the whole queue; a running job unwinds through the
///   engine's normal cancellation (partial file cleaned up), a waiting job never starts.
/// - **Live progress.** `observe()` streams a `QueueSnapshot` — every job's state plus an
///   aggregate byte total, throughput, and ETA — for the queue bar the app draws.
///
/// It lives in `DirnexCore` because it drives the byte-moving engine ("if it touches
/// bytes, it lives in DirnexCore and has tests" — §2). The heavy work runs on detached
/// tasks; the actor only bookkeeps, so its methods never block on I/O.
public actor FileOperationQueue {
    private let backend: any VFSBackend
    private let maxConcurrent: Int
    private let now: @Sendable () -> Date

    /// Every job ever enqueued, keyed by id; finished and cancelled jobs stay so the
    /// snapshot can show their outcome until the caller clears them.
    private var jobs: [OperationJobID: Job] = [:]
    /// Enqueue order — the FIFO the scheduler scans, and the render order of the snapshot.
    private var order: [OperationJobID] = []
    /// The cancel/pause handle for each job that is currently running.
    private var controls: [OperationJobID: JobControl] = [:]
    private var runningIDs: Set<OperationJobID> = []
    private var isPausedFlag = false

    /// When the current batch of work first started moving bytes, for the throughput
    /// average behind the ETA. Reset to `nil` whenever the queue drains, so a later batch
    /// measures its own rate rather than inheriting an idle gap.
    private var firstActivityAt: Date?

    private var observers: [UUID: AsyncStream<QueueSnapshot>.Continuation] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - backend: the filesystem the jobs run against; also the source of volume ids.
    ///   - maxConcurrent: a ceiling on simultaneously-running jobs, on top of the volume
    ///     rule — a backstop so a machine with many volumes doesn't spawn unbounded work.
    ///   - now: the clock, injectable so throughput/ETA is testable.
    public init(
        backend: any VFSBackend,
        maxConcurrent: Int = 8,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.maxConcurrent = max(1, maxConcurrent)
        self.now = now
    }

    // MARK: - Enqueue

    /// Add an operation to the queue and try to start it. Returns the id used to cancel it
    /// or find it in a snapshot. Jobs keep FIFO order within a volume; across volumes they
    /// may overtake one another as slots free up.
    ///
    /// `resolveConflict` is only meaningful when `conflictPolicy` is `.ask`: it is handed to
    /// the engine so a colliding item can be resolved per file (TC's conflict dialog). It
    /// runs on the job's background copy thread, so the app bridges it to a main-actor prompt.
    ///
    /// `onError` is consulted when a source fails to transfer — TC's per-file "Skip / Retry /
    /// Abort" dialog. Like `resolveConflict` it runs on the copy thread; a missing one leaves
    /// the engine's default (collect the failure and carry on).
    @discardableResult
    public func enqueue(
        _ operation: FileOperation,
        conflictPolicy: ConflictPolicy = .fail,
        resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)? = nil,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)? = nil
    ) -> OperationJobID {
        let id = OperationJobID()
        jobs[id] = Job(
            operation: operation,
            policy: conflictPolicy,
            resolveConflict: resolveConflict,
            onError: onError,
            volumes: resolveVolumes(for: operation),
            status: .waiting,
            progress: nil,
            report: nil
        )
        order.append(id)
        publish()
        pump()
        return id
    }

    /// The set of volumes a job stresses — every source's volume plus the destination's.
    /// A `nil` identifier is folded to a per-backend sentinel so unknown-volume paths all
    /// share one bucket and therefore serialize (safe: never thrash an unknown disk).
    private func resolveVolumes(for operation: FileOperation) -> Set<String> {
        var volumes = Set<String>()
        for source in operation.sources { volumes.insert(volumeKey(for: source.path)) }
        volumes.insert(volumeKey(for: operation.destinationDirectory))
        return volumes
    }

    private func volumeKey(for path: VFSPath) -> String {
        backend.volumeIdentifier(for: path) ?? "\(path.backend.rawValue):default"
    }

    // MARK: - Scheduling

    /// Launch as many waiting jobs as the volume rule and the concurrency cap allow.
    /// Called after every state change that could free a slot (enqueue, completion, resume).
    private func pump() {
        guard !isPausedFlag else { return } // paused: start nothing new (running jobs park)
        while let id = nextRunnable() { launch(id) }
    }

    /// The first waiting job (in FIFO order) whose volumes don't overlap any running job's,
    /// or `nil` if none can start right now.
    private func nextRunnable() -> OperationJobID? {
        guard runningIDs.count < maxConcurrent else { return nil }
        let busy = runningVolumes()
        return order.first { id in
            guard let job = jobs[id], job.status == .waiting else { return false }
            return job.volumes.isDisjoint(with: busy)
        }
    }

    private func runningVolumes() -> Set<String> {
        runningIDs.reduce(into: Set<String>()) { result, id in
            if let job = jobs[id] { result.formUnion(job.volumes) }
        }
    }

    private func launch(_ id: OperationJobID) {
        guard var job = jobs[id], job.status == .waiting else { return }
        job.status = .running
        jobs[id] = job
        runningIDs.insert(id)
        if firstActivityAt == nil { firstActivityAt = now() }

        let control = JobControl()
        controls[id] = control

        let operation = job.operation
        let policy = job.policy
        let resolveConflict = job.resolveConflict
        let onError = job.onError
        let backend = backend
        let (progressStream, progressContinuation) = AsyncStream<OperationProgress>.makeStream()

        // The engine is synchronous and blocks its thread; run it detached so the actor
        // stays responsive. `isCancelled` is the job's control hook — it reports
        // cancellation *and* blocks the copy while the queue is paused.
        let runTask = Task.detached(priority: .userInitiated) { () -> OperationReport in
            let report = CopyEngine.run(
                operation,
                using: backend,
                conflictPolicy: policy,
                resolveConflict: resolveConflict,
                onError: onError,
                onProgress: { progressContinuation.yield($0) },
                isCancelled: { control.checkpoint() }
            )
            progressContinuation.finish()
            return report
        }

        // Marshal progress and the final report back onto the actor. Detached (not an
        // actor-inheriting `Task`) so every hop to `self` is an unambiguous `await`.
        Task.detached { [weak self] in
            for await progress in progressStream {
                await self?.record(progress: progress, for: id)
            }
            let report = await runTask.value
            await self?.complete(id: id, report: report)
        }
    }

    private func record(progress: OperationProgress, for id: OperationJobID) {
        guard var job = jobs[id], job.status == .running || job.status == .paused else { return }
        job.progress = progress
        jobs[id] = job
        publish()
    }

    private func complete(id: OperationJobID, report: OperationReport) {
        guard var job = jobs[id] else { return }
        job.report = report
        // The engine sets `wasCancelled` when it unwound on a cancel — reflect that as a
        // cancelled job rather than a finished one, even though it produced a report.
        job.status = report.wasCancelled ? .cancelled : .finished
        jobs[id] = job
        runningIDs.remove(id)
        controls[id] = nil
        publish()
        pump()
        checkIdle()
    }

    // MARK: - Pause / resume

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

    public func resume() {
        guard isPausedFlag else { return }
        isPausedFlag = false
        for id in runningIDs {
            controls[id]?.setPaused(false)
            if var job = jobs[id], job.status == .paused {
                job.status = .running
                jobs[id] = job
            }
        }
        publish()
        pump()
    }

    public var isPaused: Bool { isPausedFlag }

    // MARK: - Cancel

    /// Cancel one job. A waiting job is dropped before it starts; a running (or paused) job
    /// is told to unwind — the engine cleans up any half-written file and reports back with
    /// `wasCancelled`, at which point `complete` marks it cancelled.
    public func cancel(_ id: OperationJobID) {
        guard var job = jobs[id] else { return }
        switch job.status {
        case .waiting:
            job.status = .cancelled
            jobs[id] = job
            publish()
            checkIdle()
        case .running, .paused:
            controls[id]?.cancel() // completion arrives via the engine's cancelled report
        case .finished, .cancelled:
            break
        }
    }

    public func cancelAll() {
        for id in order { cancel(id) }
    }

    // MARK: - Housekeeping

    /// Drop every finished or cancelled job from the queue, leaving waiting, running, and
    /// paused jobs untouched. The aggregate rolls up *all* known jobs, so without this a
    /// later batch would inherit the bytes of jobs already done — its progress bar would
    /// start part-full. The app calls this once the queue drains, matching a queue bar that
    /// vanishes when idle and reappears fresh for the next batch.
    public func clearFinished() {
        var removedAny = false
        for (id, job) in jobs where job.status == .finished || job.status == .cancelled {
            jobs[id] = nil
            removedAny = true
        }
        guard removedAny else { return }
        order.removeAll { jobs[$0] == nil }
        publish()
    }

    // MARK: - Internal job record

    /// The actor's private, mutable view of a job. The `Sendable` outward shape is
    /// `JobSnapshot`; this stays inside the actor.
    private struct Job {
        let operation: FileOperation
        let policy: ConflictPolicy
        /// The per-file conflict resolver, only used when `policy` is `.ask` (see `enqueue`).
        let resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?
        /// The per-file error resolver (skip/retry/abort); `nil` keeps the collect-and-carry
        /// default (see `enqueue`).
        let onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?
        let volumes: Set<String>
        var status: JobStatus
        var progress: OperationProgress?
        var report: OperationReport?
    }
}

// MARK: - Snapshots & observation

extension FileOperationQueue {
    /// The current state of the whole queue — a one-shot read for a caller that doesn't
    /// want a stream.
    public func snapshot() -> QueueSnapshot { currentSnapshot() }

    /// A live stream of queue snapshots: the current state immediately, then a fresh one on
    /// every change. Each caller gets its own stream; drop it (let it deinit) to unsubscribe.
    public func observe() -> AsyncStream<QueueSnapshot> {
        let (stream, continuation) = AsyncStream<QueueSnapshot>.makeStream()
        let key = UUID()
        observers[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(key) }
        }
        continuation.yield(currentSnapshot())
        return stream
    }

    private func removeObserver(_ key: UUID) {
        observers[key] = nil
    }

    /// Suspend until no job is waiting, running, or paused. Handy for callers (and tests)
    /// that want to act once the batch is fully drained.
    public func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    var isIdle: Bool {
        !jobs.values.contains { $0.status == .waiting || $0.status == .running || $0.status == .paused }
    }

    func checkIdle() {
        guard isIdle else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        firstActivityAt = nil // next batch measures its own throughput
    }

    func publish() {
        let snapshot = currentSnapshot()
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    private func currentSnapshot() -> QueueSnapshot {
        let jobSnapshots = order.compactMap { id -> JobSnapshot? in
            guard let job = jobs[id] else { return nil }
            return JobSnapshot(
                id: id,
                kind: job.operation.kind,
                status: job.status,
                progress: job.progress,
                report: job.report
            )
        }
        return QueueSnapshot(
            jobs: jobSnapshots,
            aggregate: aggregate(over: jobSnapshots),
            isPaused: isPausedFlag
        )
    }

    /// Roll every job's known bytes into a batch total, and derive throughput/ETA from the
    /// average rate since the batch began moving. Bytes a job hasn't been scanned for yet
    /// (still waiting) count as `0`, so early in a big batch the total grows as jobs start
    /// and the ETA is a lower bound — honest, and it tightens as scanning completes.
    private func aggregate(over jobs: [JobSnapshot]) -> AggregateProgress {
        var totalBytes: Int64 = 0
        var completedBytes: Int64 = 0
        var finished = 0
        var active = 0
        for job in jobs {
            totalBytes += job.progress?.totalBytes ?? 0
            completedBytes += job.report?.completedBytes ?? job.progress?.completedBytes ?? 0
            switch job.status {
            case .finished, .cancelled: finished += 1
            case .running, .paused: active += 1
            case .waiting: break
            }
        }
        let elapsed = firstActivityAt.map { now().timeIntervalSince($0) } ?? 0
        let bytesPerSecond = elapsed > 0 ? Double(completedBytes) / elapsed : 0
        let remaining = max(0, totalBytes - completedBytes)
        let eta: TimeInterval? = (bytesPerSecond > 0 && remaining > 0)
            ? Double(remaining) / bytesPerSecond
            : nil
        return AggregateProgress(
            totalJobs: jobs.count,
            finishedJobs: finished,
            activeJobs: active,
            totalBytes: totalBytes,
            completedBytes: completedBytes,
            bytesPerSecond: bytesPerSecond,
            estimatedTimeRemaining: eta
        )
    }
}

// MARK: - Job control

/// The shared cancel/pause handle between the actor and a job's detached engine run.
///
/// The engine polls one closure — its `isCancelled` — between chunks and items. We route
/// that through `checkpoint`, which does double duty: it reports cancellation, and while
/// the queue is paused it *blocks the copy thread* on a condition variable until the job
/// is resumed or cancelled. That gives a real mid-flight pause without the engine needing
/// to know the queue exists. A plain lock-guarded flag pair, safe to touch from the actor
/// and the copy thread alike.
private final class JobControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var paused = false

    func cancel() {
        condition.lock()
        cancelled = true
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
        while paused, !cancelled { condition.wait() }
        return cancelled
    }
}
