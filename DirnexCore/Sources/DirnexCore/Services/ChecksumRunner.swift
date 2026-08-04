/// Executes a checksum `FileOperation` — write a manifest, or verify one (PLAN.md §M14 Slice 2).
///
/// `CopyEngine`'s shape exactly, and deliberately so: a plain synchronous entry point returning an
/// `OperationReport`, progress reported through a throttled callback, cancellation polled between
/// units, and the caller deciding where it runs. That is what lets `FileOperationQueue` schedule a
/// checksum beside a copy with no second scheduler — same volume rule, same pause, same cancel,
/// same queue bar. Hashing a 50 GB file is ~25 s of SHA-256 and ~100 s of CRC32; a modal sheet over
/// that is the thing PLAN.md §1 forbids.
///
/// **Local only.** Neither `sftp` nor `curl` can hash server-side, so a remote checksum is a full
/// download — genuinely useful, and its own slice, because it needs a streaming read neither remote
/// backend exposes yet. Until then a non-local job fails fast with ``ChecksumError/needsLocalFile``
/// rather than half-working.
///
/// The two modes live in `ChecksumCreateRun` and `ChecksumVerifyRun`, over the shared
/// `ChecksumRunContext` that owns the byte tally and the one call that touches bytes. Split by
/// concept rather than shaved to fit: they share a progress bar and nothing else — one writes a
/// file, the other reads one.
public enum ChecksumRunner {
    /// Run a checksum operation, returning the queue's report with ``OperationReport/checksum``
    /// filled in.
    ///
    /// - `operation.kind` must be `.checksum`; anything else returns an empty report rather than
    ///   trapping, so a queue dispatch bug degrades to "nothing happened" instead of a crash.
    /// - `onProgress` reports bytes hashed against the byte total measured by the walk, so the bar
    ///   is determinate from the first update.
    /// - `isCancelled` is polled between chunks *and* between files; cancelling a `.create` leaves
    ///   no manifest behind at all — a half-written checksum file is worse than none, because it
    ///   verifies clean while covering a fraction of the tree.
    public static func run(
        _ operation: FileOperation,
        using backend: any VFSBackend,
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> OperationReport {
        guard case let .checksum(job) = operation.kind else { return .empty }
        let context = ChecksumRunContext(
            job: job,
            backend: backend,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
        guard job.manifest.backend == .local else {
            return context.report(outcome: .failed(.needsLocalFile))
        }
        switch job {
        case let .create(manifest, algorithm):
            return ChecksumCreateRun(context: context)
                .execute(sources: operation.sources, manifest: manifest, algorithm: algorithm)
        case let .verify(manifest):
            return ChecksumVerifyRun(context: context).execute(manifest: manifest)
        }
    }
}
