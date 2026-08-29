import Foundation

/// How a finished archive gets from where it was built to where it was asked for, and how that half
/// of the work reaches the bar (PLAN.md §4 ▸ *Smaller than a milestone*).
///
/// ``PackStaging`` already answers *where does the archive go*; this answers *what does the queue
/// see while it goes there*, which is the half both pack runners need and neither should own. The
/// encrypted runner has had it since M24 Slice 6 and the plain one arrived on the queue two
/// milestones later — so this is one definition rather than the second spelling that would drift on
/// the first change to either, which is the same argument `PackStaging`'s own comment makes one
/// layer down.
struct PackDelivery {
    let staging: PackStaging
    /// Where the job asked for the archive, which is also what the status line names while it moves.
    let archive: VFSPath
    /// How many members went in — reported unchanged throughout, because delivery adds no items.
    let itemCount: Int
    /// What the walk measured, which is what the bar counted up to while the archive was written.
    let packedBytes: Int64
    /// What the finished archive weighs, which is what a transfer then moves.
    let archiveBytes: Int64

    /// The bar's denominator once the transfer is part of the job.
    ///
    /// **The upload's bytes are added to the total rather than replacing it**, so the bar grows once
    /// at the transition and then runs on to the end. Both alternatives are things this project has
    /// already paid for: leaving the total alone parks a *full* bar for the length of a network
    /// transfer, which reads as a finished job that has hung, and starting a fresh total walks the
    /// aggregate backwards (docs/NOTES.md ▸ AppKit, on a coalescer that latches).
    var total: Int64 { packedBytes + (staging.needsDelivery ? archiveBytes : 0) }

    /// Put the archive where it belongs, reporting as it moves.
    ///
    /// ``PackDeliveryOutcome/delivered`` also covers *there was nothing to deliver*, which is every
    /// local pack — the writer already landed on the destination, and a caller that treated "no
    /// transfer" as a distinct answer would have two shapes of success to keep in step.
    func run(
        using backend: any VFSBackend,
        onProgress: @escaping @Sendable (OperationProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> PackDeliveryOutcome {
        let archive = archive
        let total = total
        let packedBytes = packedBytes
        let itemCount = itemCount
        do {
            try staging.deliver(
                to: archive,
                byteSize: archiveBytes,
                using: backend,
                onBytes: { moved in
                    onProgress(
                        OperationProgress(
                            totalBytes: total,
                            completedBytes: packedBytes + moved,
                            totalItems: itemCount,
                            completedItems: itemCount,
                            currentItem: archive
                        )
                    )
                },
                isCancelled: isCancelled
            )
            return .delivered
        } catch is CancellationError {
            return .cancelled
        } catch {
            // The write succeeded and the transfer did not, so the honest report is neither a
            // created archive nor a failure of the *pack*: it is the backend's own refusal about the
            // path it refused (the rule `ChecksumRunContext.recordFailure` follows — a `VFSError`
            // normalized through an errno becomes `.io`, a code nobody can look up standing in for
            // "the bucket is read-only").
            return .failed((error as? VFSError) ?? .io(path: archive, code: 0))
        }
    }
}

/// What became of the transfer that puts a finished archive where it was asked for.
enum PackDeliveryOutcome {
    /// Landed — or there was nothing to move, which is every local pack.
    case delivered
    case cancelled
    /// The archive was written and could not be put where it belongs. The error is the backend's
    /// own, about the destination path, rather than anything the pack has a vocabulary for.
    case failed(VFSError)
}
