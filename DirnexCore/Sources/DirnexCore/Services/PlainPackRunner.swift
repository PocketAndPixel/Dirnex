import Foundation

/// Executes a `.plainPack` operation: spawn `bsdtar` through the injected writer, then put the
/// archive where it was asked for (PLAN.md §4 ▸ *Smaller than a milestone*).
///
/// ``PackRunner``'s shape exactly, and deliberately: a synchronous entry point returning an
/// `OperationReport`, progress through a callback, cancellation polled by the writer underneath, and
/// the caller deciding where it runs. The two share ``PackStaging`` for *where the archive goes* and
/// ``PackDelivery`` for *what the bar sees while it goes there*, so the only thing that differs
/// between an encrypted pack and a plain one is the twenty lines that write bytes.
///
/// **The bar is determinate, which is not what a `bsdtar` pack looks like from outside.** The tool
/// prints no progress and no flag turns one on — what it has is SIGINFO, which the writer signals
/// and ``BsdtarProgress`` reads, giving *bytes read from the sources*. That is the same quantity the
/// walk here measures in advance, so the numerator and the denominator are the same kind of thing.
/// A bar keyed on the archive's own growth could not be: its denominator is a compression ratio
/// nobody knows until the end.
public enum PlainPackRunner {
    /// Run a plain pack, returning the queue's report with ``OperationReport/pack`` filled in.
    ///
    /// - `operation.kind` must be `.plainPack`; anything else returns an empty report rather than
    ///   trapping, the way every runner here degrades a dispatch bug to "nothing happened".
    /// - `writer` is the app's `bsdtar`. A `nil` one is a **wiring** failure rather than a dispatch
    ///   one, so it is reported as the archive failing with "no tool" instead of degrading to
    ///   silence: a queue that accepted the job and did nothing is the quietest possible bug, and
    ///   this project has paid for that shape more than once (docs/NOTES.md ▸ Design lessons, on a
    ///   seam whose default is "can't help").
    /// - `isCancelled` is polled by the walk and passed to the writer, which must reach the process
    ///   itself. A cancelled pack leaves nothing at the destination.
    public static func run(
        _ operation: FileOperation,
        using backend: any VFSBackend,
        writer: (any PlainPackWriting)?,
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> OperationReport {
        guard case let .plainPack(job) = operation.kind else { return .empty }
        guard let writer else {
            return failed(job, with: .unsupported(.archiveToolUnavailableForCreate))
        }
        let staging: PackStaging
        do {
            staging = try PackStaging(for: job.archive)
        } catch {
            return report(outcome: .failed(.archiveNotWritable))
        }
        defer { staging.clean() }

        do {
            return try write(
                Build(job: job, staging: staging, writer: writer),
                using: backend,
                onProgress: onProgress,
                isCancelled: isCancelled
            )
        } catch is CancellationError {
            return report(outcome: nil, wasCancelled: true)
        } catch {
            // Everything that reaches here is about a *path* — the walk found a source that stopped
            // being readable, or `bsdtar` could not run or did not land an archive — so it goes home
            // as the backend's own `VFSError` rather than being flattened into a code nobody can
            // look up (the rule `ChecksumRunContext.recordFailure` follows).
            return failed(job, with: (error as? VFSError) ?? .unsupported(.archiveCreateFailed(
                archive: job.archive.lastComponent
            )))
        }
    }

    /// What one pack is, once the runner has settled where it builds and who writes it.
    private struct Build {
        let job: PlainPackJob
        let staging: PackStaging
        let writer: any PlainPackWriting
    }

    /// Walk the sources for the denominator, write the archive, and deliver it.
    private static func write(
        _ build: Build,
        using backend: any VFSBackend,
        onProgress: @escaping @Sendable (OperationProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> OperationReport {
        let job = build.job
        let staging = build.staging
        // `allowDataless: true` keeps a plain pack behaving exactly as it always has. The encrypted
        // path refuses a placeholder the walk discovers, because reading one downloads it and its
        // writer is the thing that would do the reading; here the reader is `bsdtar`, which has
        // never asked, and turning that into a refusal would be a new "no" nobody requested in a
        // slice about a progress bar. What the walk is for here is the byte total, and a
        // placeholder's `stat` supplies that without moving a byte.
        let items = try ArchiveSourceEnumerator.items(
            for: job.sources,
            allowDataless: true,
            isCancelled: isCancelled
        )
        let totalBytes = ArchiveSourceEnumerator.totalByteSize(of: items)
        let itemCount = items.count
        // Where each member's bytes came from, so the status line can name the file on disk rather
        // than the bare name `bsdtar` reports. Built from the walk, which is the one thing holding
        // both halves — `PackRunner` does the same with its own writer's names.
        let onDiskPaths = Dictionary(
            items.map { ($0.archivePath, $0.onDiskPath) },
            uniquingKeysWith: { first, _ in first }
        )
        let archive = job.archive
        // Determinate from the first update rather than from the first sample: `bsdtar` says
        // nothing until it is asked, and the first ask is a poll interval away.
        onProgress(
            OperationProgress(
                totalBytes: totalBytes,
                completedBytes: 0,
                totalItems: itemCount,
                completedItems: 0,
                currentItem: archive
            )
        )
        try build.writer.pack(
            job.request(buildingAt: staging.buildPath),
            onProgress: { sample in
                onProgress(
                    OperationProgress(
                        // Clamped because the two counts are measured by different things: the walk
                        // counts regular files' bytes and `bsdtar` counts everything it reads, so a
                        // tree of many small files can report past the total. A bar that overshoots
                        // reads as a job that has lost track of itself.
                        totalBytes: totalBytes,
                        completedBytes: min(sample.bytesRead, totalBytes),
                        totalItems: itemCount,
                        completedItems: min(sample.filesRead, itemCount),
                        currentItem: sample.currentItem.map {
                            .local(onDiskPaths[$0] ?? $0)
                        } ?? archive
                    )
                )
            },
            isCancelled: isCancelled
        )
        let delivery = PackDelivery(
            staging: staging,
            archive: archive,
            itemCount: itemCount,
            packedBytes: totalBytes,
            archiveBytes: staging.builtByteSize
        )
        switch delivery.run(using: backend, onProgress: onProgress, isCancelled: isCancelled) {
        case .delivered:
            return report(
                outcome: .created(
                    PackSummary(
                        archive: archive,
                        itemCount: itemCount,
                        byteSize: delivery.archiveBytes,
                        encryption: .none,
                        namePrivacy: .visible
                    )
                ),
                completedItems: itemCount,
                completedBytes: delivery.total
            )
        case .cancelled:
            return report(outcome: nil, wasCancelled: true)
        case let .failed(error):
            return failed(job, with: error)
        }
    }

    /// One failed path, as this job's whole report.
    ///
    /// A `failures` entry rather than ``PackOutcome/failed(_:)``, which carries an
    /// `EncryptedArchiveError` — a vocabulary about libarchive that a `bsdtar` spawn has no business
    /// borrowing. The window reports a queued job's failures already, so this needs no new surface.
    private static func failed(_ job: PlainPackJob, with error: VFSError) -> OperationReport {
        OperationReport(
            completedItems: 0,
            completedBytes: 0,
            skipped: [],
            failures: [OperationItemFailure(path: job.archive, error: error)],
            wasCancelled: false
        )
    }

    private static func report(
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
