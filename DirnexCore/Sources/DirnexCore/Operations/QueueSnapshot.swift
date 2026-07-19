import Foundation

/// The `Sendable` value types the `FileOperationQueue` publishes — the outward shape of a
/// job and the whole-queue rollup the app's queue bar renders (PLAN.md §M2 "Progress UI").
/// They live apart from the actor so the actor file stays focused on scheduling.

/// Opaque handle to an enqueued job — returned by `enqueue`, used to `cancel` and to find
/// the job in a `QueueSnapshot`.
public struct OperationJobID: Hashable, Sendable, CustomStringConvertible {
    private let raw: UUID
    public init() { raw = UUID() }
    public var description: String { raw.uuidString }
}

/// Where a job is in its lifecycle. A job goes `waiting → running → finished`, may be
/// `paused` while running, and can reach `cancelled` from any non-terminal state.
public enum JobStatus: Sendable, Equatable {
    case waiting
    case running
    case paused
    case finished
    case cancelled
}

/// One job's outward state in a `QueueSnapshot`.
public struct JobSnapshot: Sendable, Equatable, Identifiable {
    public let id: OperationJobID
    public let kind: FileOperation.Kind
    public let status: JobStatus
    /// The last progress the engine reported, or `nil` before the job has started.
    public let progress: OperationProgress?
    /// The final report, present once the job has finished or been cancelled mid-flight.
    public let report: OperationReport?

    public init(
        id: OperationJobID,
        kind: FileOperation.Kind,
        status: JobStatus,
        progress: OperationProgress?,
        report: OperationReport?
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.progress = progress
        self.report = report
    }
}

/// The whole-queue rollup the progress bar draws from.
public struct AggregateProgress: Sendable, Equatable {
    public let totalJobs: Int
    /// Jobs in a terminal state — finished or cancelled.
    public let finishedJobs: Int
    /// Jobs currently running or paused.
    public let activeJobs: Int
    /// Sum of scanned byte totals across jobs. Grows as still-waiting jobs get scanned, so
    /// treat it as a running estimate early in a batch, exact once nothing is waiting.
    public let totalBytes: Int64
    public let completedBytes: Int64
    /// Average throughput since the batch began, `0` before anything measurable.
    public let bytesPerSecond: Double
    /// Seconds of known work remaining at the current rate, or `nil` when not yet estimable
    /// (no rate, or nothing left to do).
    public let estimatedTimeRemaining: TimeInterval?

    public init(
        totalJobs: Int,
        finishedJobs: Int,
        activeJobs: Int,
        totalBytes: Int64,
        completedBytes: Int64,
        bytesPerSecond: Double,
        estimatedTimeRemaining: TimeInterval?
    ) {
        self.totalJobs = totalJobs
        self.finishedJobs = finishedJobs
        self.activeJobs = activeJobs
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.bytesPerSecond = bytesPerSecond
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }

    /// Fraction complete in `0...1`. Prefers the byte ratio; falls back to the job count
    /// before any bytes are known so the bar still advances between instant operations.
    public var fraction: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        return totalJobs > 0 ? Double(finishedJobs) / Double(totalJobs) : 0
    }
}

/// An immutable snapshot of the whole queue at one instant.
public struct QueueSnapshot: Sendable, Equatable {
    public let jobs: [JobSnapshot]
    public let aggregate: AggregateProgress
    public let isPaused: Bool

    public init(jobs: [JobSnapshot], aggregate: AggregateProgress, isPaused: Bool) {
        self.jobs = jobs
        self.aggregate = aggregate
        self.isPaused = isPaused
    }

    /// Nothing left to do — every job is finished or cancelled.
    public var isIdle: Bool {
        jobs.allSatisfy { $0.status == .finished || $0.status == .cancelled }
    }
}
