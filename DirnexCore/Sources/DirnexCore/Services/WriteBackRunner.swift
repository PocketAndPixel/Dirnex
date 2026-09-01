import Foundation

/// Executes a `.writeBack` operation: put a batch of edited copies back where they came from
/// (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// `MaterializeRunner`'s shape exactly, pointing the other way — a synchronous entry point
/// returning an `OperationReport`, progress through a callback, cancellation polled between items
/// and inside each transfer, and the caller deciding where it runs. Being a queue job rather than a
/// loop somewhere in the app is the whole of the slice: before it, a user script that rewrote forty
/// files on a server produced forty independent uploads with no combined bar, no Stop and no
/// ordering between them, each one a `Task` the window started and then forgot.
///
/// **It decides nothing about whether a write *should* happen.** Every item arrives carrying the
/// precondition the check already settled, because that check is what the user was shown and
/// answered — and re-deciding it here would be a second definition of "may this overwrite", made
/// out of the runner's view of the world instead of the one the user agreed to
/// (`BrowserWindowController.writeBackConcern`). The runner's job is bytes and reporting.
///
/// **Nothing here is undoable, and that is a property rather than an omission.** The report carries
/// no ``OperationReport/outcomes``, so `UndoJournal` has nothing to build a record from — which is
/// right, and is what every write-back confirmation has said since M21 Slice 10: an upload replaces
/// the server's copy, and the version a reversal would need is the one it just destroyed.
public enum WriteBackRunner {
    /// Upload every item, reporting as it goes.
    ///
    /// - `operation.kind` must be `.writeBack`. A mismatch returns an empty report rather than
    ///   trapping, the way every other runner degrades a dispatch bug to "nothing happened".
    /// - An item that fails is recorded and the run **continues**, which is the choice a batch
    ///   makes and a single save cannot see: thirty-nine edits must not be abandoned because the
    ///   fortieth file's server refused it. The caller reads ``OperationReport/failures`` and
    ///   decides what to say — including the two refusals a *precondition* produces, which are a
    ///   question rather than an error and are re-offered rather than reported.
    /// - `isCancelled` is polled between items and inside each transfer. Stopping mid-batch leaves
    ///   the items already sent **sent** — an upload cannot be taken back — so the report names
    ///   exactly which ones landed rather than a count nobody can act on.
    public static func run(
        _ operation: FileOperation,
        using backend: any VFSBackend,
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> OperationReport {
        guard case let .writeBack(job) = operation.kind else { return .empty }

        // Known before the first byte moves, because every source is a file on this disk: unlike a
        // materialize — whose folders can only be measured when their turn comes — there is nothing
        // here a listing could fail to state, so the bar is determinate from the first update.
        let totalBytes = job.totalBytes
        var written: [VFSPath] = []
        var failures: [OperationItemFailure] = []
        var completedBytes: Int64 = 0

        for item in job.items {
            if isCancelled() {
                return report(written, failures, completedBytes, job, cancelled: true)
            }
            // Constants, because the progress closure is `@Sendable`: it may read what this
            // iteration decided and must not see the running totals move under it.
            let before = completedBytes
            let done = written.count + failures.count
            let step: @Sendable (Int64) -> Void = { moved in
                onProgress(
                    OperationProgress(
                        totalBytes: totalBytes,
                        completedBytes: before + moved,
                        totalItems: job.items.count,
                        completedItems: done,
                        currentItem: item.destination
                    )
                )
            }
            step(0)
            do {
                try backend.writeBack(
                    localPath: item.localPath,
                    to: item.destination,
                    condition: item.condition,
                    progress: { step($0) },
                    isCancelled: { isCancelled() }
                )
                written.append(item.destination)
                // From the copy's own size, never from what the transfer reported: an `sftp` upload
                // prints no meter a spawned process can read (docs/NOTES.md ▸ sftp / ssh), so a bar
                // driven by the transport alone would sit short of the total it started with.
                completedBytes = before + max(0, item.byteSize)
            } catch is CancellationError {
                return report(written, failures, before, job, cancelled: true)
            } catch {
                completedBytes = before
                // `CopyEngine`'s own spelling: a backend error is already a `VFSError`, and
                // anything else can only have come from the file manager, which the destination
                // names better than a code nobody can look up.
                let failure = (error as? VFSError) ?? .io(path: item.destination, code: 0)
                failures.append(OperationItemFailure(path: item.destination, error: failure))
            }
        }
        return report(written, failures, completedBytes, job, cancelled: false)
    }

    private static func report(
        _ written: [VFSPath],
        _ failures: [OperationItemFailure],
        _ completedBytes: Int64,
        _ job: WriteBackJob,
        cancelled: Bool
    ) -> OperationReport {
        OperationReport(
            completedItems: written.count,
            completedBytes: completedBytes,
            skipped: [],
            failures: failures,
            wasCancelled: cancelled,
            // Empty rather than `nil` even when nothing landed: a caller reading the destinations
            // has to be able to tell "this job wrote nothing" from "this was not a write-back".
            writtenBack: written
        )
    }
}
