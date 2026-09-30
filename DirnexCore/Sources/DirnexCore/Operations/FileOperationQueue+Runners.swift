import Foundation

/// Which engine runs a queued job — the only thing an operation's *kind* decides.
///
/// Split out of `FileOperationQueue` when the plain pack joined (PLAN.md §4 ▸ *Smaller than a
/// milestone*), on the file-length ceiling and on the better reason underneath it: everything else
/// the queue does — the volume rule, pause, cancel, the aggregate bar — is engine-agnostic by
/// construction, which is why a checksum, a pack and a materialize could each join without a
/// scheduler of their own. This file is the one place that is not.
extension FileOperationQueue {
    /// What a job's conflict handling needs, as one value: three arguments that only ever travel
    /// together, and only for the two kinds that move a user's files.
    struct Resolvers {
        let policy: ConflictPolicy
        let resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?
        let onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?
    }

    /// What every runner here is given, whatever its kind: where the bytes live, who can spawn
    /// `bsdtar`, and the two callbacks the queue reports and stops through.
    struct Context {
        let backend: any VFSBackend
        let plainPackWriter: (any PlainPackWriting)?
        let onProgress: @Sendable (OperationProgress) -> Void
        let isCancelled: @Sendable () -> Bool
        let resolvers: Resolvers
    }

    /// Run `operation` to completion on the calling thread, which is a `BlockingWork` thread.
    static func report(for operation: FileOperation, in context: Context) -> OperationReport {
        let backend = context.backend
        let plainPackWriter = context.plainPackWriter
        let onProgress = context.onProgress
        let isCancelled = context.isCancelled
        let resolvers = context.resolvers
        let report: OperationReport
        switch operation.kind {
        case .copy, .move:
            report = CopyEngine.run(
                operation,
                using: backend,
                conflictPolicy: resolvers.policy,
                resolveConflict: resolvers.resolveConflict,
                onError: resolvers.onError,
                onProgress: { onProgress($0) },
                isCancelled: { isCancelled() }
            )
        case let .attributes(job):
            report = AttributeApplyRunner.run(
                job,
                sources: operation.sources,
                using: backend,
                onProgress: { onProgress($0) },
                isCancelled: { isCancelled() }
            )
        case .checksum:
            report = ChecksumRunner.run(
                operation,
                using: backend,
                onProgress: { onProgress($0) },
                isCancelled: { isCancelled() }
            )
        case .pack:
            report = PackRunner.run(
                operation,
                using: backend,
                onProgress: { onProgress($0) },
                isCancelled: { isCancelled() }
            )
        case .plainPack:
            report = PlainPackRunner.run(
                operation,
                using: backend,
                writer: plainPackWriter,
                onProgress: { onProgress($0) },
                isCancelled: { isCancelled() }
            )
        case .materialize:
            report = MaterializeRunner.run(
                operation,
                using: backend,
                onProgress: { onProgress($0) },
                isCancelled: { isCancelled() }
            )
        case .writeBack:
            report = WriteBackRunner.run(
                operation,
                using: backend,
                onProgress: { onProgress($0) },
                isCancelled: { isCancelled() }
            )
        }
        return report
    }
}
