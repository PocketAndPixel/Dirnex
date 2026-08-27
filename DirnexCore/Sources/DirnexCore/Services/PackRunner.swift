import Foundation

/// Executes a pack `FileOperation` — write an encrypted archive (PLAN.md §M19 Slice 2).
///
/// `ChecksumRunner`'s shape exactly: a synchronous entry point returning an `OperationReport`,
/// progress through a callback, cancellation polled by the engine underneath, and the caller
/// deciding where it runs. That is what lets `FileOperationQueue` schedule a pack beside a copy with
/// no second scheduler, and it is the whole reason the encrypted path was worth putting on the queue
/// — AES-256 over a folder of photographs is minutes of work, and a modal sheet over that is the
/// thing PLAN.md §1 forbids. Everything the queue offers is what this needs: one job per volume,
/// pause, cancel, and a determinate bar.
///
/// **Encrypted only, and the sources are always already here.** The writer reads real paths through
/// libarchive, which is what ``PackSource`` guarantees: whatever a row was on — a bucket, a server, a
/// browsed archive — the gesture staged it before queueing this (PLAN.md §M24 Slice 6). A `.none` job
/// is legal and writes an ordinary zip through the same code — worth keeping so the two cannot drift
/// — but the app queues one only when there is a passphrase, because an unencrypted pack has no
/// reason to leave `bsdtar`.
///
/// **The destination need not be local.** An archive bound for a server is built in a temp directory
/// and transferred with the backend's own verb afterwards — `ChecksumCreateRun`'s shape for a
/// manifest that belongs beside a bucket's objects, and the mirror of the download `MaterializeRunner`
/// performs in the other direction. There is deliberately no pre-flight capability check: a backend
/// that cannot receive the archive says so in its own words, and that sentence is better than one of
/// ours guessing at it.
public enum PackRunner {
    /// Run a pack operation, returning the queue's report with ``OperationReport/pack`` filled in.
    ///
    /// - `operation.kind` must be `.pack`; anything else returns an empty report rather than
    ///   trapping, so a queue dispatch bug degrades to "nothing happened" instead of a crash.
    /// - `onProgress` reports bytes written against the byte total the *walk* measured, so the bar is
    ///   determinate from the first update rather than growing as directories are discovered.
    /// - `isCancelled` is polled between chunks and between entries. A canceled pack leaves nothing
    ///   behind: the archive is built under a temporary name and only renamed into place on success,
    ///   so there is no half-archive to find later and mistake for a whole one.
    /// - A destination on a server adds a transfer after the write, whose refusal comes home as an
    ///   ``OperationItemFailure`` carrying the backend's own `VFSError` rather than being flattened
    ///   into this job's own vocabulary — the archive really was written, and what failed was
    ///   putting it somewhere.
    public static func run(
        _ operation: FileOperation,
        using backend: any VFSBackend,
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> OperationReport {
        guard case let .pack(job) = operation.kind else { return .empty }
        let staging: PackStaging
        do {
            staging = try PackStaging(for: job.archive)
        } catch {
            return report(job: job, outcome: .failed(.archiveNotWritable))
        }
        defer { staging.clean() }

        do {
            return try write(
                job,
                into: staging,
                using: backend,
                onProgress: onProgress,
                isCancelled: isCancelled
            )
        } catch is CancellationError {
            return report(job: job, outcome: nil, wasCancelled: true)
        } catch let error as EncryptedArchiveError {
            return report(job: job, outcome: .failed(error))
        } catch {
            // Anything else reaching here came from the source walk — a directory that stopped being
            // readable between the marking and the walk. It is about a *path*, so it goes home as a
            // `VFSError` failure rather than being flattened into the job-level vocabulary.
            return failed(job, with: (error as? VFSError) ?? .unsupported(.archiveCreateFailed(
                archive: job.archive.lastComponent
            )))
        }
    }

    /// Walk the sources, write the archive into `staging`, and put it where the job asked for it.
    private static func write(
        _ job: PackJob,
        into staging: PackStaging,
        using backend: any VFSBackend,
        onProgress: @escaping @Sendable (OperationProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> OperationReport {
        let items = try ArchiveSourceEnumerator.items(
            for: job.sources,
            allowDataless: job.allowDataless,
            isCancelled: isCancelled
        )
        // Where each member's bytes were read from, so the queue bar's status line can name the file
        // rather than a bare archive-relative name. Built from the walk's own output because that is
        // the one thing holding both halves; with a staged set there is no directory to prepend,
        // which is exactly what `PackSource` exists to say.
        let onDiskPaths = Dictionary(
            items.map { ($0.archivePath, $0.onDiskPath) },
            uniquingKeysWith: { first, _ in first }
        )
        try EncryptedArchiveWriter.write(
            items: items,
            toArchiveAt: staging.buildPath,
            encryption: job.encryption,
            passphrase: job.passphrase,
            namePrivacy: job.namePrivacy,
            level: job.level,
            onProgress: { progress in
                onProgress(
                    OperationProgress(
                        totalBytes: progress.totalBytes,
                        completedBytes: progress.bytesWritten,
                        totalItems: progress.totalItems,
                        completedItems: progress.itemsWritten,
                        currentItem: .local(
                            onDiskPaths[progress.currentName] ?? progress.currentName
                        )
                    )
                )
            },
            isCancelled: isCancelled
        )
        // Measured on the file that exists, before it is delivered and before the staging directory
        // is swept: a remote destination cannot be `stat`ed without another round trip, and the
        // number is only ever a status line.
        let delivery = Delivery(
            staging: staging,
            job: job,
            itemCount: items.count,
            packedBytes: ArchiveSourceEnumerator.totalByteSize(of: items),
            archiveBytes: staging.builtByteSize
        )
        if let refusal = deliver(
            delivery,
            using: backend,
            onProgress: onProgress,
            isCancelled: isCancelled
        ) {
            return refusal
        }
        return report(
            job: job,
            outcome: .created(
                PackSummary(
                    archive: job.archive,
                    itemCount: items.count,
                    byteSize: delivery.archiveBytes,
                    encryption: job.encryption,
                    namePrivacy: job.namePrivacy
                )
            ),
            completedItems: items.count,
            completedBytes: delivery.total
        )
    }

    /// What the delivery step needs to know, as one value.
    ///
    /// A struct rather than six arguments because two of them are byte counts that mean different
    /// things — what the *sources* weighed and what the *archive* weighs — and a parameter list is
    /// where those two get swapped.
    private struct Delivery {
        let staging: PackStaging
        let job: PackJob
        let itemCount: Int
        /// What the walk measured, which is what the bar counted up to during the write.
        let packedBytes: Int64
        /// What the finished archive weighs, which is what a transfer then moves.
        let archiveBytes: Int64

        /// The bar's denominator once the transfer is part of the job.
        var total: Int64 { packedBytes + (staging.needsDelivery ? archiveBytes : 0) }
    }

    /// One failed path, as this job's whole report.
    private static func failed(_ job: PackJob, with error: VFSError) -> OperationReport {
        OperationReport(
            completedItems: 0,
            completedBytes: 0,
            skipped: [],
            failures: [OperationItemFailure(path: job.archive, error: error)],
            wasCancelled: false
        )
    }

    /// Put the finished archive where the job asked for it, reporting as it moves — or hand back the
    /// report that says why it could not.
    ///
    /// `nil` means delivered (or that there was nothing to deliver, which is every local pack).
    ///
    /// **The upload's bytes are added to the total rather than replacing it**, so the bar grows once
    /// at the transition and then runs on to the end. Both alternatives are things this project has
    /// already paid for: leaving the total alone parks a *full* bar for the length of a network
    /// transfer, which reads as a finished job that has hung, and starting a fresh total walks the
    /// aggregate backwards.
    private static func deliver(
        _ delivery: Delivery,
        using backend: any VFSBackend,
        onProgress: @escaping @Sendable (OperationProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> OperationReport? {
        let job = delivery.job
        do {
            try delivery.staging.deliver(
                to: job.archive,
                byteSize: delivery.archiveBytes,
                using: backend,
                onBytes: { moved in
                    onProgress(
                        OperationProgress(
                            totalBytes: delivery.total,
                            completedBytes: delivery.packedBytes + moved,
                            totalItems: delivery.itemCount,
                            completedItems: delivery.itemCount,
                            currentItem: job.archive
                        )
                    )
                },
                isCancelled: isCancelled
            )
            return nil
        } catch is CancellationError {
            return report(job: job, outcome: nil, wasCancelled: true)
        } catch {
            // The write succeeded and the transfer did not, so the honest report is neither
            // `.created` nor an `EncryptedArchiveError`: it is the backend's own refusal about the
            // path it refused (the rule `ChecksumRunContext.recordFailure` follows — a `VFSError`
            // normalized through an errno becomes `.io`, a code nobody can look up standing in for
            // "the bucket is read-only").
            return failed(job, with: (error as? VFSError) ?? .io(path: job.archive, code: 0))
        }
    }

    private static func report(
        job: PackJob,
        outcome: PackOutcome?,
        completedItems: Int = 0,
        completedBytes: Int64 = 0,
        wasCancelled: Bool = false
    ) -> OperationReport {
        OperationReport(
            completedItems: completedItems,
            completedBytes: completedBytes,
            skipped: [],
            failures: [],
            wasCancelled: wasCancelled,
            pack: outcome
        )
    }
}
