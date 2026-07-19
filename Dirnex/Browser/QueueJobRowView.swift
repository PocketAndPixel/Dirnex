import AppKit
import DirnexCore

/// One row in the queue bar's expandable per-job list (PLAN.md §M2 "Progress UI"): a single
/// queued copy/move, showing what it is, a per-job determinate progress bar, its byte detail,
/// and its own cancel button. The row renders from a `JobSnapshot` and reports a cancel back
/// through a callback — like `QueueBarView`, it knows nothing about the queue actor.
@MainActor
final class QueueJobRowView: NSView {
    /// The fixed height of one row; the bar multiplies it to size the expanded list.
    static let preferredHeight: CGFloat = 30

    /// Fired when this row's cancel button is clicked, carrying the job to cancel.
    var onCancel: ((OperationJobID) -> Void)?

    private var jobID: OperationJobID?
    private let nameLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()

    /// Like the header readout, a running job's byte count arrives many times a second; we
    /// coalesce it to at most once a second. Fixed-word states (Waiting/Paused/Done/…) still
    /// refresh instantly, since a status change forces a refresh — see `update(with:)`.
    private static let detailRefreshInterval: TimeInterval = 1
    private var lastDetailRefresh: Date = .distantPast
    private var lastStatus: JobStatus?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLayout() {
        nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byClipping
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        cancelButton.image = NSImage(
            systemSymbolName: "xmark.circle",
            accessibilityDescription: "Cancel"
        )
        cancelButton.imagePosition = .imageOnly
        cancelButton.isBordered = false
        cancelButton.bezelStyle = .toolbar
        cancelButton.contentTintColor = .tertiaryLabelColor
        cancelButton.toolTip = "Cancel this operation"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)

        // Cancel and bar lead (mirroring the header) so they stay put; the byte readout follows
        // the bar and the name flexes at the trailing edge. Indenting to `cancelColumnInset`
        // puts this cancel button — and, one control over, this bar — directly under the header's.
        let stack = NSStackView(views: [cancelButton, bar, statusLabel, nameLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = QueueBarMetrics.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: QueueBarMetrics.cancelColumnInset,
            bottom: 0,
            right: QueueBarMetrics.edgeInset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: QueueBarMetrics.controlWidth),
            bar.widthAnchor.constraint(equalToConstant: 90)
        ])
    }

    /// Render one job's state. Waiting/paused jobs show a label in place of a live rate;
    /// a terminal job hides its cancel button since there is nothing left to stop. The bar
    /// tracks every snapshot; only the fast-moving byte readout is coalesced (see below).
    func update(with job: JobSnapshot) {
        jobID = job.id
        let verb = job.kind == .copy ? "Copy" : "Move"
        let name = job.progress?.currentItem?.lastComponent
        nameLabel.stringValue = name.map { "\(verb) \($0)" } ?? "\(verb)…"

        switch job.status {
        case .waiting: bar.doubleValue = 0
        case .running, .paused: bar.doubleValue = job.progress?.fraction ?? 0
        case .finished: bar.doubleValue = 1
        case .cancelled: break
        }

        updateStatusLabel(for: job)
        cancelButton.isHidden = job.status == .finished || job.status == .cancelled
    }

    /// Refresh the trailing readout, coalescing the running byte count to once a second so it's
    /// legible. Every other status is a fixed word, and a status change forces an immediate
    /// refresh, so transitions (start, pause, done) never look stuck behind the throttle.
    private func updateStatusLabel(for job: JobSnapshot) {
        let statusChanged = lastStatus != job.status
        lastStatus = job.status

        switch job.status {
        case .waiting: statusLabel.stringValue = "Waiting"
        case .paused: statusLabel.stringValue = "Paused"
        case .finished: statusLabel.stringValue = "Done"
        case .cancelled: statusLabel.stringValue = "Cancelled"
        case .running:
            guard statusChanged
                || Date().timeIntervalSince(lastDetailRefresh) >= Self.detailRefreshInterval
            else { return }
            lastDetailRefresh = Date()
            statusLabel.stringValue = byteDetail(for: job.progress)
        }
    }

    private func byteDetail(for progress: OperationProgress?) -> String {
        guard let progress, progress.totalBytes > 0 else { return "" }
        let done = Self.byteFormatter.string(fromByteCount: progress.completedBytes)
        let total = Self.byteFormatter.string(fromByteCount: progress.totalBytes)
        return "\(done) / \(total)"
    }

    @objc private func cancelClicked() {
        guard let jobID else { return }
        onCancel?(jobID)
    }
}
