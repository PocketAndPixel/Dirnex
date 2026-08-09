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
/// **Local only, and encrypted only.** The writer reads and writes real paths through libarchive, so
/// a job naming a remote backend fails fast with ``EncryptedArchiveError/needsLocalFile`` rather than
/// half-working. A `.none` job is legal and writes an ordinary zip through the same code — worth
/// keeping so the two cannot drift — but the app queues one only when there is a passphrase, because
/// an unencrypted pack has no reason to leave `bsdtar`.
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
    public static func run(
        _ operation: FileOperation,
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> OperationReport {
        guard case let .pack(job) = operation.kind else { return .empty }
        guard job.archive.backend == .local, job.sourceDirectory.backend == .local else {
            return report(job: job, outcome: .failed(.needsLocalFile))
        }

        do {
            let items = try ArchiveSourceEnumerator.items(
                inDirectory: job.sourceDirectory.path,
                names: job.names,
                allowDataless: job.allowDataless,
                isCancelled: isCancelled
            )
            let totalBytes = ArchiveSourceEnumerator.totalByteSize(of: items)
            try EncryptedArchiveWriter.write(
                items: items,
                toArchiveAt: job.archive.path,
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
                            currentItem: job.sourceDirectory.appending(progress.currentName)
                        )
                    )
                },
                isCancelled: isCancelled
            )
            return report(
                job: job,
                outcome: .created(
                    PackSummary(
                        archive: job.archive,
                        itemCount: items.count,
                        byteSize: byteSize(ofFileAt: job.archive.path),
                        encryption: job.encryption,
                        namePrivacy: job.namePrivacy
                    )
                ),
                completedItems: items.count,
                completedBytes: totalBytes
            )
        } catch is CancellationError {
            return report(job: job, outcome: nil, wasCancelled: true)
        } catch let error as EncryptedArchiveError {
            return report(job: job, outcome: .failed(error))
        } catch {
            // Anything else reaching here came from the source walk — a directory that stopped being
            // readable between the marking and the walk. It is about a *path*, so it goes home as a
            // `VFSError` failure rather than being flattened into the job-level vocabulary.
            return OperationReport(
                completedItems: 0,
                completedBytes: 0,
                skipped: [],
                failures: [
                    OperationItemFailure(
                        path: job.sourceDirectory,
                        error: (error as? VFSError) ?? .unsupported(.archiveCreateFailed(
                            archive: job.archive.lastComponent
                        ))
                    )
                ],
                wasCancelled: false
            )
        }
    }

    /// The finished archive's size, or `0` when it cannot be stat-ed — a number for the status line,
    /// never a claim the pack depends on, so a failed `stat` must not fail the job that just
    /// succeeded.
    private static func byteSize(ofFileAt path: String) -> Int64 {
        var status = stat()
        guard lstat(path, &status) == 0 else { return 0 }
        return Int64(status.st_size)
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
