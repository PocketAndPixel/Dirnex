import AppKit
import DirnexCore

/// The window's bridge to the shared `FileOperationQueue` (PLAN.md §M2): it enqueues the
/// panes' copy/move operations, drives the queue bar from the live snapshot stream, and
/// re-lists both panes as jobs finish. All byte work and scheduling live in the tested
/// `DirnexCore` queue; this is the AppKit shell over it.
extension BrowserWindowController {
    // MARK: - PanelHost

    func enqueue(
        _ operation: FileOperation,
        conflictPolicy: ConflictPolicy,
        resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?
    ) {
        let queue = queue
        Task {
            await queue.enqueue(
                operation,
                conflictPolicy: conflictPolicy,
                resolveConflict: resolveConflict,
                onError: onError
            )
        }
    }

    // MARK: - Observation

    /// Drain the queue's snapshot stream into the UI for the window's lifetime. The task is
    /// cancelled in `deinit`; `[weak self]` with a per-iteration re-bind keeps the window
    /// from being pinned alive by the loop while it waits for the next snapshot.
    func startObservingQueue() {
        queueObservation = Task { [weak self] in
            guard let queue = self?.queue else { return }
            let stream = await queue.observe()
            for await snapshot in stream {
                guard let self else { break }
                handle(snapshot)
            }
        }
    }

    private func handle(_ snapshot: QueueSnapshot) {
        lastPaused = snapshot.isPaused
        // React to any job that just reached a terminal state before deciding visibility, so
        // the final completion still refreshes the panes even as the bar collapses.
        finalizeCompletedJobs(in: snapshot)

        if snapshot.isIdle {
            setQueueBar(visible: false)
            // Batch drained: forget it so the next batch's bar starts from zero rather than
            // inheriting the finished jobs' bytes.
            if !snapshot.jobs.isEmpty {
                finalizedJobs.removeAll()
                let queue = queue
                Task { await queue.clearFinished() }
            }
        } else {
            setQueueBar(visible: true)
            queueBar.update(with: snapshot)
        }
    }

    /// For each newly-finished (or cancelled) job, re-list both panes so the source (for a
    /// move) and destination reflect the change at once, and surface any failures. The
    /// FSEvents watchers would catch up on their own, but an explicit refresh is immediate.
    private func finalizeCompletedJobs(in snapshot: QueueSnapshot) {
        for job in snapshot.jobs where job.status == .finished || job.status == .cancelled {
            guard finalizedJobs.insert(job.id).inserted else { continue }
            refreshPanes()
            guard let report = job.report else { continue }
            // Journal whatever landed (even a cancelled job's partial work) so Cmd+Z can
            // reverse it; `transfer` returns nil when nothing is reversible.
            if let record = UndoRecord.transfer(kind: job.kind, outcomes: report.outcomes) {
                undoController.record(record)
            }
            if !report.failures.isEmpty {
                reportFailures(report, kind: job.kind)
            }
        }
    }

    private func refreshPanes() {
        leftPanel.refreshCurrentDirectory()
        rightPanel.refreshCurrentDirectory()
    }

    private func reportFailures(_ report: OperationReport, kind: FileOperation.Kind) {
        let verb = kind == .copy ? "copy" : "move"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = report.failures.count == 1
            ? "Couldn’t \(verb) “\(report.failures[0].path.lastComponent)”"
            : "Couldn’t \(verb) \(report.failures.count) items"
        // Reuse the pane's error phrasing (pure — it only switches on the error).
        alert.informativeText = leftPanel.describe(report.failures[0].error)
        alert.addButton(withTitle: "OK")
        alert.enableEscapeToCancel()
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - Queue-bar controls

    func togglePause() {
        let queue = queue
        let shouldPause = !lastPaused
        Task {
            if shouldPause { await queue.pause() } else { await queue.resume() }
        }
    }

    func cancelAllJobs() {
        let queue = queue
        Task { await queue.cancelAll() }
    }

    /// Cancel one job from the queue bar's per-job list. A waiting job is dropped; a running
    /// one unwinds through the engine's normal cancel (partial file cleaned up).
    func cancelJob(_ id: OperationJobID) {
        let queue = queue
        Task { await queue.cancel(id) }
    }
}
