import AppKit
import DirnexCore

/// Running a `.materialize` job for a gesture that needs real paths, and handing its answer back
/// to whichever gesture that was (PLAN.md §M24 Slice 3).
///
/// The window is where this has to live, because it owns all three of the things involved: the
/// queue the job runs on, the `RemoteFileCache` the copies are filed in, and the lifetime that
/// outlives the pane — a marked set of remote objects is minutes, during which the user may change
/// tabs, switch panes or navigate away, and the gesture still owes them an answer.
///
/// **Nothing here decides anything.** Whether the set was worth downloading was settled before the
/// job was queued (`MaterializationPlan` and `RemoteFetchPolicy`, in the pane), and what to do with
/// the copies afterwards belongs to the gesture. This is the transport between the two.
extension BrowserWindowController {
    /// Queue a download of `entries` and call `then` with the report when it finishes, however it
    /// finished — landed, stopped, or failed partway.
    ///
    /// The copies are adopted into `remoteFileCache` first, so a second gesture over the same rows
    /// costs nothing: mark four objects, run Open With, then Share two of them, and only the first
    /// gesture transfers anything.
    func materializeRemoteFiles(
        _ entries: [FileEntry],
        then: @escaping @MainActor (OperationReport) -> Void
    ) {
        let operation = FileOperation(
            kind: .materialize,
            sources: entries,
            destinationDirectory: .local(RemoteFileCache.temporaryRoot.path)
        )
        let queue = queue
        let deliveries = materializeDeliveries
        Task {
            let id = await queue.enqueue(operation)
            deliveries.expect(id, then: then)
        }
    }

    /// Hand a finished `.materialize` job's report to the gesture waiting on it, having filed its
    /// copies where every other surface will find them.
    ///
    /// Called from the one place a finished job is noticed (`finalizeCompletedJobs`), so a
    /// materialize reaches its gesture by the same path a copy reaches the undo journal.
    func deliverMaterializeReport(_ report: OperationReport, for id: OperationJobID) {
        remoteFileCache.adopt(report.materialized ?? [])
        materializeDeliveries.deliver(report, for: id)
    }
}

/// Where a queued `.materialize` job's report meets the gesture that asked for it.
///
/// **Two halves that can arrive in either order, which is the whole reason this is a type.**
/// `FileOperationQueue.enqueue` is an actor method, so the job's id — the only thing the two halves
/// share — exists only *after* the job has been accepted and could already be running; a transfer
/// that fails on its first request can therefore complete before the caller has finished writing
/// down what to do about it. Registering and delivering both go through the same pairing here, and
/// whichever arrives second fires, so there is no ordering to get right at the call sites.
///
/// It is one object rather than two dictionaries on `BrowserWindowController` for the ordinary
/// reason (that type sits near SwiftLint's body ceiling) and for a better one: the pairing rule is
/// the thing worth keeping in one place, and split across two properties it would be a rule two
/// call sites have to remember.
@MainActor
final class MaterializeDeliveries {
    private var waiting: [OperationJobID: @MainActor (OperationReport) -> Void] = [:]
    private var arrived: [OperationJobID: OperationReport] = [:]

    /// Say what to do with `id`'s report when it comes — or now, if it already has.
    func expect(_ id: OperationJobID, then: @escaping @MainActor (OperationReport) -> Void) {
        if let report = arrived.removeValue(forKey: id) {
            then(report)
            return
        }
        waiting[id] = then
    }

    /// Deliver `id`'s report to whoever is waiting — or hold it until somebody is.
    func deliver(_ report: OperationReport, for id: OperationJobID) {
        if let handler = waiting.removeValue(forKey: id) {
            handler(report)
            return
        }
        arrived[id] = report
    }
}
