/// Executes a checksum `FileOperation` — write a manifest, or verify one (PLAN.md §M14 Slice 2).
///
/// `CopyEngine`'s shape exactly, and deliberately so: a plain synchronous entry point returning an
/// `OperationReport`, progress reported through a throttled callback, cancellation polled between
/// units, and the caller deciding where it runs. That is what lets `FileOperationQueue` schedule a
/// checksum beside a copy with no second scheduler — same volume rule, same pause, same cancel,
/// same queue bar. Hashing a 50 GB file is ~25 s of SHA-256 and ~100 s of CRC32; a modal sheet over
/// that is the thing PLAN.md §1 forbids.
///
/// **Hashing still only ever reads this disk; the rows need not be on it** (PLAN.md §M24 Slice 4).
/// Neither `sftp` nor `curl` can hash server-side, so a remote checksum is a full download — and
/// the download is the *gesture's*, which is the milestone's one structural rule. What reaches here
/// is `operation.materialized`: which file on this disk stands for each row, so the manifest keeps
/// the server's own names while `ChecksumEngine` is handed real paths. A row with no stand-in is
/// reported as ``ChecksumEntryStatus/notDownloaded`` rather than failing the job, which is the same
/// answer an evicted cloud placeholder already gave.
///
/// There is deliberately **no pre-flight guard on the manifest's own backend**. A `.create` into a
/// bucket is an upload the backend performs and a browsed archive refuses in its own words, which
/// beats a sentence invented here; a `.verify` with no copy of its manifest answers
/// ``ChecksumError/needsLocalFile`` from the run that noticed, one file along.
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
    /// - `isCancelled` is polled between chunks *and* between files; canceling a `.create` leaves
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
            materialized: operation.materialized,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
        switch job {
        case let .create(manifest, algorithm):
            return ChecksumCreateRun(context: context)
                .execute(sources: operation.sources, manifest: manifest, algorithm: algorithm)
        case let .verify(manifest):
            return ChecksumVerifyRun(context: context).execute(manifest: manifest)
        }
    }
}
