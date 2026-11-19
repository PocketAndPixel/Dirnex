import AppKit
import DirnexCore

/// The copy and move dialog for one F5 or F6 (PLAN.md §M41): it asks, then follows the transfer's
/// jobs through the queue's snapshots until they end or the user sends them to the background.
///
/// The jobs run in the window's queue exactly as they always have, so the queue bar shows them too;
/// this is only a second view of them, and closing it never touches them. What it adds is Pause
/// for these jobs alone (``FileOperationQueue/pause(_:)``) and a Cancel that asks first, with the
/// jobs paused behind the question.
@MainActor
final class TransferDialog {
    /// What the dialog asks of the queue, as closures so it never holds the actor itself.
    struct QueueControl {
        let pause: (OperationJobID) -> Void
        let resume: (OperationJobID) -> Void
        let cancel: (OperationJobID) -> Void
    }

    /// How long the dialog stays up after OK, however fast the transfer ends. A clone is done in the
    /// turn it starts, and without this the second of two quick Returns would land on the file list,
    /// where it opens whatever is under the cursor; with it, that Return presses Background.
    static let minimumShown: TimeInterval = 1
    /// How often the bytes, rate and time left are redrawn: slow enough to read, the queue bar's
    /// reason for its own one-second pace.
    private static let detailInterval: TimeInterval = 0.5

    private let summary: TransferSummary
    let controller: TransferDialogController
    private let control: QueueControl
    private let onClose: () -> Void
    private let uptime: () -> TimeInterval
    private let preferences: AppPreferences
    private weak var presenter: NSViewController?

    /// The transfer's jobs, in the order they were queued, and the last snapshot seen of each.
    private var ids: [OperationJobID] = []
    private var known: [OperationJobID: JobSnapshot] = [:]
    private var isSubmitting = true
    private var queueContext = TransferDialogState.Queue()
    private(set) var state = TransferDialogState(phase: .preparing)

    private var confirmedAt: TimeInterval?
    /// Seconds spent running, for the rate: time paused or waiting is not copying time.
    private var runningSeconds: TimeInterval = 0
    private var lastRunningTick: TimeInterval?
    private var detailTimer: Timer?
    private var stopQuestion: NSAlert?
    private var isFinishing = false
    private(set) var isClosed = false

    init(
        summary: TransferSummary,
        control: QueueControl,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        preferences: AppPreferences = .shared,
        onClose: @escaping () -> Void
    ) {
        self.summary = summary
        self.control = control
        self.uptime = uptime
        self.preferences = preferences
        self.onClose = onClose
        controller = TransferDialogController(summary: summary)
    }

    /// Ask, as a sheet on `presenter`'s window. `start` runs on OK, and never on Cancel, with the
    /// folder the field names.
    func present(
        from presenter: NSViewController,
        start: @escaping (TransferTracker, VFSPath) -> Void
    ) {
        self.presenter = presenter
        wire(start: start)
        presenter.presentAsSheet(controller)
    }

    /// The buttons, apart from presenting, so a test can drive the dialog without a sheet.
    func wire(start: @escaping (TransferTracker, VFSPath) -> Void) {
        controller.onConfirm = { [weak self] dontAskAgain in
            self?.confirm(dontAskAgain: dontAskAgain, start: start)
        }
        controller.onCancel = { [weak self] in self?.cancelPressed() }
        controller.onPause = { [weak self] in self?.togglePause() }
        controller.onBackground = { [weak self] in self?.close() }
    }

    /// Follow the transfer's jobs through one queue snapshot.
    func handle(_ snapshot: QueueSnapshot) {
        guard confirmedAt != nil, !isClosed else { return }
        let tracked = Set(ids)
        for job in snapshot.jobs where tracked.contains(job.id) {
            known[job.id] = job
        }
        queueContext = TransferDialogState.Queue(
            othersActive: snapshot.jobs.contains {
                !tracked.contains($0.id) && ($0.status == .running || $0.status == .paused)
            },
            isPaused: snapshot.isPaused
        )
        refresh()
    }

    // MARK: - Asking

    /// OK: check the folder the field names with the dialog still up, then start. A folder that is
    /// not there yet is the pane's to make, as Oleg asked on 2026-11-19, so it passes here; one the
    /// items cannot go into is said under the field, and the dialog keeps asking.
    private func confirm(dontAskAgain: Bool, start: (TransferTracker, VFSPath) -> Void) {
        guard !isClosed else { return }
        let destination = controller.typedDestination
        if let refusal = summary.refusal(destination) {
            controller.showRefusal(refusal)
            return
        }
        if dontAskAgain {
            // The box answers this copy too: someone who wants no dialogs gets none now either.
            preferences.confirmTransfers = false
            close()
            start(.untracked, destination)
            return
        }
        confirmedAt = uptime()
        controller.showProgress(destination: destination)
        startDetailTimer()
        start(
            TransferTracker(
                onTrack: { [weak self] id in self?.ids.append(id) },
                onFinish: { [weak self] in
                    self?.isSubmitting = false
                    self?.refresh()
                }
            ),
            destination
        )
    }

    // MARK: - Following the jobs

    private func refresh() {
        guard confirmedAt != nil, !isClosed else { return }
        let previous = state.phase
        state = TransferDialogState.read(
            ids.compactMap { known[$0] },
            tracked: ids.count,
            isSubmitting: isSubmitting,
            queue: queueContext
        )
        tickRunningClock()
        // The readout keeps its own pace, except when the phase changes, which it says at once.
        controller.render(state, detail: state.phase == previous ? nil : detailText())
        if state.phase == .done { finish() }
    }

    private func tickRunningClock() {
        let now = uptime()
        if let last = lastRunningTick { runningSeconds += now - last }
        lastRunningTick = state.phase == .running ? now : nil
    }

    /// The readout under the bars, with the rate measured over the time spent running.
    func detailText() -> String {
        let rate = runningSeconds > 0.25 ? Double(state.completedBytes) / runningSeconds : 0
        let remaining = state.totalBytes - state.completedBytes
        let eta: TimeInterval? = rate > 0 && remaining > 0 ? Double(remaining) / rate : nil
        return TransferDialogText.detail(state, bytesPerSecond: rate, estimatedTimeRemaining: eta)
    }

    private func startDetailTimer() {
        // `.common`, so the readout keeps moving while a menu is open or a pane scrolls; the queue
        // bar's timer runs the same way.
        let timer = Timer(timeInterval: Self.detailInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                self.tickRunningClock()
                self.controller.render(self.state, detail: self.detailText())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        detailTimer = timer
    }

    // MARK: - Pause and Cancel

    /// The jobs that can still be paused, resumed or canceled: every one not seen to end.
    private var openIDs: [OperationJobID] {
        ids.filter { id in
            guard let status = known[id]?.status else { return true }
            return status != .finished && status != .cancelled
        }
    }

    private func setPaused(_ paused: Bool) {
        for id in openIDs {
            if paused { control.pause(id) } else { control.resume(id) }
        }
    }

    private func togglePause() {
        guard state.phase != .done else { return }
        setPaused(!state.isHeld)
    }

    private func cancelPressed() {
        switch controller.phase {
        case .asking:
            close() // nothing was queued
        case .progress:
            if state.phase == .done { close() } else { askToStop() }
        }
    }

    /// Pause the jobs and ask whether to stop them. Continue resumes them, unless they were paused
    /// before Cancel was pressed, in which case they stay as the user left them.
    private func askToStop() {
        guard stopQuestion == nil, let sheet = controller.view.window else { return }
        let wasHeld = state.isHeld
        setPaused(true)
        let alert = Self.stopQuestion(kind: summary.kind)
        stopQuestion = alert
        alert.beginSheet(on: sheet) { [weak self] response in
            guard let self else { return }
            stopQuestion = nil
            if response == .alertFirstButtonReturn {
                for id in openIDs { control.cancel(id) }
            } else if response == .alertSecondButtonReturn, !wasHeld {
                setPaused(false)
            }
        }
    }

    /// "Stop copying?", with Stop on Return and Continue on Escape: Escape, Return from the progress
    /// dialog stops the transfer, and a second Escape takes it back. Built apart from presenting so a
    /// test can read its keys, since presenting an alert inside the test host kills it
    /// (docs/NOTES.md ▸ The keyboard in a dialog).
    static func stopQuestion(kind: FileOperation.Kind) -> NSAlert {
        let words = TransferDialogText.stopQuestion(kind: kind)
        let alert = NSAlert()
        alert.messageText = words.message
        alert.informativeText = words.detail
        alert.addButton(
            withTitle: String(
                localized: "Stop",
                comment: "Copy progress dialog: stops the copy or move."
            )
        )
        alert.addButton(withTitle: String(
            localized: "Continue",
            comment: "Copy progress dialog: carries on with the copy or move instead of stopping it."
        ))
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)
        return alert
    }

    // MARK: - Closing

    /// Every job has ended: close once the dialog has been up `minimumShown`, and once nothing hangs
    /// from it, since a conflict, an error or the failure report can be attached to it.
    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        if let alert = stopQuestion, let sheet = controller.view.window {
            sheet.endSheet(alert.window) // the question is moot; its handler ignores this response
        }
        controller.render(state, detail: detailText())
        let wait = max(0, Self.minimumShown - (uptime() - (confirmedAt ?? uptime())))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            while let sheet = self?.controller.view.window, sheet.attachedSheet != nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.close()
        }
    }

    /// Take the dialog down. The jobs are not touched: Background leaves them running in the queue.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        detailTimer?.invalidate()
        detailTimer = nil
        if controller.presentingViewController != nil {
            presenter?.dismiss(controller)
        }
        onClose()
    }
}
