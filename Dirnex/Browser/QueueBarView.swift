import AppKit
import DirnexCore

/// Shared layout metrics for the queue bar, so the header's controls and each per-job row's
/// controls line up in fixed columns. Both lay out a leading run of fixed-width buttons, then
/// the progress bar, then the readout, then a flexible name at the trailing edge — that
/// ordering keeps everything the user clicks (bar and buttons) anchored to the left edge
/// instead of drifting as the name and byte readout change width. The header leads with `disclosure · pause ·
/// cancel`; a row omits the first two and indents to `cancelColumnInset` so its cancel button
/// sits directly under the header's, and its bar under the header's bar.
enum QueueBarMetrics {
    /// Left/right padding inside the header and each job row.
    static let edgeInset: CGFloat = 12
    /// Fixed footprint of each borderless symbol button, so a row's cancel lines up under the
    /// header's regardless of which glyph each shows.
    static let controlWidth: CGFloat = 22
    /// Gap between adjacent elements in the header and row stacks.
    static let spacing: CGFloat = 10
    /// Leading inset of the cancel button: past the disclosure chevron and the pause button.
    /// A job row uses this as its left inset so every cancel button shares one column.
    static let cancelColumnInset = edgeInset + (controlWidth + spacing) * 2
}

/// The window-bottom queue bar (PLAN.md §M2 "Progress UI"): a non-blocking readout of the
/// shared `FileOperationQueue`. Unlike the old modal progress sheet, it lets the user keep
/// browsing while a large transfer runs in the background — TC's killer feature.
///
/// A compact header row — the disclosure chevron plus pause/resume and cancel-all controls,
/// then an aggregate determinate bar, a byte/throughput/ETA readout, and finally what's
/// happening (the item name) — sits over an expandable per-job list: the disclosure chevron reveals one row per queued
/// copy/move, each with its own progress and cancel button. Leading the row with the fixed-
/// width controls and bar keeps them from drifting as the name and readout change width (see
/// `QueueBarMetrics`). The bar renders from a `QueueSnapshot` and knows nothing about the queue
/// actor — the window controller feeds it snapshots, wires the buttons back, and follows the
/// bar's `preferredHeight` as the list expands and collapses.
@MainActor
final class QueueBarView: NSView {
    /// The bar's height with the per-job list collapsed; the window controller collapses it
    /// to zero when idle and grows it to `preferredHeight` as jobs are disclosed.
    static let collapsedHeight: CGFloat = 42
    /// Rows shown before the list starts scrolling, so a big batch can't eat the window.
    private static let maxVisibleRows = 5
    /// Breathing room above and below the job rows inside the scroll area.
    private static let listPadding: CGFloat = 6

    /// Fired when the pause/resume button is clicked; the window controller toggles the
    /// queue. The bar doesn't own queue state — it re-renders from the next snapshot.
    var onPauseToggle: (() -> Void)?
    /// Fired when the cancel-all button is clicked.
    var onCancelAll: (() -> Void)?
    /// Fired when a per-job row's cancel button is clicked, carrying the job to cancel.
    var onCancelJob: ((OperationJobID) -> Void)?
    /// Fired when `preferredHeight` changes (disclosure toggled, or the job count crossed a
    /// row boundary while expanded) so the window controller can resize the bar to match.
    var onPreferredHeightChanged: (() -> Void)?

    private let disclosureButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let pauseButton = NSButton()
    private let cancelButton = NSButton()

    let jobScroll = NSScrollView()
    let jobStack = NSStackView()
    var jobListHeight: NSLayoutConstraint!
    /// Live per-job rows, reused across snapshots and keyed by job so a steady stream of
    /// progress updates edits them in place instead of rebuilding the list.
    var jobRows: [OperationJobID: QueueJobRowView] = [:]
    /// The jobs currently shown, in order — the fast-path key: an unchanged list just
    /// updates rows in place, a changed one rebuilds and re-reports the height.
    var displayedJobIDs: [OperationJobID] = []
    var isExpanded = false
    var lastReportedHeight: CGFloat = QueueBarView.collapsedHeight

    /// The byte/throughput/ETA readout arrives many times a second; refreshing the label that
    /// fast makes it a blur. We coalesce it to at most once a second (with an immediate refresh
    /// when the paused state flips) — see `update(with:)`.
    private static let detailRefreshInterval: TimeInterval = 1
    private var lastDetailRefresh: Date = .distantPast
    private var lastPausedState: Bool?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let etaFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
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
        configureAggregateViews()
        let header = makeHeaderStack()
        buildJobList()

        // A hairline separator divides the bar from the panes above it.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        jobScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(header)
        addSubview(jobScroll)

        // The scroll view's fixed height (0 when collapsed) drives the whole layout: pinned to
        // the bottom, it pushes the header up to fill the fixed-height top band above it.
        jobListHeight = jobScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            header.topAnchor.constraint(equalTo: separator.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            jobScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            jobScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            jobScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            jobScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            jobListHeight
        ])
        jobScroll.isHidden = true
        refreshDisclosure()
    }

    private func configureAggregateViews() {
        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
    }

    private func makeHeaderStack() -> NSStackView {
        configure(
            disclosureButton,
            symbol: "chevron.right",
            accessibility: "Show operation details",
            action: #selector(disclosureClicked)
        )
        configure(
            pauseButton,
            symbol: "pause.fill",
            accessibility: "Pause",
            action: #selector(pauseClicked)
        )
        configure(
            cancelButton,
            symbol: "xmark.circle.fill",
            accessibility: "Cancel all",
            action: #selector(cancelClicked)
        )

        // Controls and bar lead so they stay put; the readout follows the bar and the name
        // flexes at the trailing edge.
        let stack = NSStackView(
            views: [disclosureButton, pauseButton, cancelButton, bar, detailLabel, statusLabel]
        )
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = QueueBarMetrics.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: QueueBarMetrics.edgeInset, bottom: 0, right: QueueBarMetrics.edgeInset
        )
        NSLayoutConstraint.activate([bar.widthAnchor.constraint(equalToConstant: 160)])
        return stack
    }

    private func buildJobList() {
        jobStack.orientation = .vertical
        jobStack.alignment = .leading
        jobStack.spacing = 0
        jobStack.translatesAutoresizingMaskIntoConstraints = false

        jobScroll.drawsBackground = false
        jobScroll.hasVerticalScroller = true
        jobScroll.autohidesScrollers = true
        jobScroll.borderType = .noBorder
        jobScroll.documentView = jobStack

        let clip = jobScroll.contentView
        NSLayoutConstraint.activate([
            jobStack.topAnchor.constraint(equalTo: clip.topAnchor, constant: Self.listPadding / 2),
            jobStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            jobStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            jobStack.widthAnchor.constraint(equalTo: clip.widthAnchor)
        ])
    }

    private func configure(
        _ button: NSButton,
        symbol: String,
        accessibility: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .toolbar
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = accessibility
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        // A fixed footprint keeps the header's and rows' buttons in aligned columns.
        button.widthAnchor.constraint(equalToConstant: QueueBarMetrics.controlWidth).isActive = true
    }

    // MARK: - Rendering

    /// Render the current state of the queue. The window controller decides overall
    /// visibility (it hides the bar when the queue is idle); this fills in the aggregate
    /// header, refreshes the per-job list, and re-reports its height if the list grew or shrank.
    func update(with snapshot: QueueSnapshot) {
        let aggregate = snapshot.aggregate
        bar.doubleValue = aggregate.fraction
        statusLabel.stringValue = statusText(for: snapshot)

        // Coalesce the fast-moving detail readout to once a second so it's legible, but refresh
        // it immediately when the run pauses or resumes so that transition never looks stuck.
        let pausedChanged = lastPausedState != snapshot.isPaused
        if pausedChanged || Date().timeIntervalSince(lastDetailRefresh) >= Self.detailRefreshInterval {
            detailLabel.stringValue = detailText(for: aggregate, paused: snapshot.isPaused)
            lastDetailRefresh = Date()
            lastPausedState = snapshot.isPaused
        }

        let symbol = snapshot.isPaused ? "play.fill" : "pause.fill"
        let title = snapshot.isPaused ? "Resume" : "Pause"
        pauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        pauseButton.toolTip = title

        updateJobList(snapshot)
        refreshDisclosure()
        syncHeight()
    }

    private func statusText(for snapshot: QueueSnapshot) -> String {
        let active = snapshot.jobs.filter { $0.status == .running || $0.status == .paused }
        let pending = snapshot.jobs.filter { $0.status == .waiting }.count

        var text: String
        if let current = active.first {
            let verb = current.kind == .copy ? "Copying" : "Moving"
            if let name = current.progress?.currentItem?.lastComponent, !name.isEmpty {
                text = "\(verb) \(name)"
            } else {
                text = "\(verb)…"
            }
        } else {
            text = "Preparing…"
        }
        if snapshot.isPaused { text = "Paused — \(text)" }

        let more = max(0, active.count - 1) + pending
        if more > 0 { text += "  (+\(more) more)" }
        return text
    }

    private func detailText(for aggregate: AggregateProgress, paused: Bool) -> String {
        let done = Self.byteFormatter.string(fromByteCount: aggregate.completedBytes)
        let total = Self.byteFormatter.string(fromByteCount: aggregate.totalBytes)
        var parts = ["\(done) of \(total)"]
        if !paused, aggregate.bytesPerSecond > 0 {
            let rate = Self.byteFormatter.string(fromByteCount: Int64(aggregate.bytesPerSecond))
            parts.append("\(rate)/s")
            if let eta = aggregate.estimatedTimeRemaining, let text = Self.etaFormatter.string(
                from: eta
            ) {
                parts.append("\(text) left")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    @objc private func pauseClicked() { onPauseToggle?() }
    @objc private func cancelClicked() { onCancelAll?() }

    @objc private func disclosureClicked() {
        isExpanded.toggle()
        refreshDisclosure()
        syncHeight()
    }
}

// MARK: - Per-job list

extension QueueBarView {
    /// The bar's height including the disclosed job list: the collapsed header plus, when
    /// expanded, up to `maxVisibleRows` rows (more scroll). The window controller sizes the
    /// bar to this and follows `onPreferredHeightChanged` as it changes.
    var preferredHeight: CGFloat { Self.collapsedHeight + listHeight }

    /// Height of the job-list area alone — zero unless the list is expanded and non-empty.
    private var listHeight: CGFloat {
        guard isExpanded, !displayedJobIDs.isEmpty else { return 0 }
        let visible = min(displayedJobIDs.count, Self.maxVisibleRows)
        return CGFloat(visible) * QueueJobRowView.preferredHeight + Self.listPadding
    }

    /// The jobs worth listing individually: the ones still in flight or waiting. Terminal
    /// jobs are summarized by the aggregate bar and cleared once the batch drains.
    private func displayedJobs(in snapshot: QueueSnapshot) -> [JobSnapshot] {
        snapshot.jobs.filter { $0.status == .waiting || $0.status == .running || $0.status == .paused }
    }

    /// Reconcile the row views against the snapshot. The common case — the same jobs in the
    /// same order — just refreshes each row in place; a changed set rebuilds the list.
    func updateJobList(_ snapshot: QueueSnapshot) {
        let jobs = displayedJobs(in: snapshot)
        let ids = jobs.map(\.id)
        if ids == displayedJobIDs {
            for job in jobs { jobRows[job.id]?.update(with: job) }
        } else {
            rebuildJobRows(jobs)
            displayedJobIDs = ids
        }
    }

    private func rebuildJobRows(_ jobs: [JobSnapshot]) {
        for row in jobStack.arrangedSubviews { row.removeFromSuperview() }
        jobRows.removeAll(keepingCapacity: true)
        for job in jobs {
            let row = QueueJobRowView()
            row.onCancel = { [weak self] id in self?.onCancelJob?(id) }
            jobStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: QueueJobRowView.preferredHeight),
                row.widthAnchor.constraint(equalTo: jobStack.widthAnchor)
            ])
            row.update(with: job)
            jobRows[job.id] = row
        }
    }

    /// Point the chevron at the current state and hide the list when there's nothing to show.
    func refreshDisclosure() {
        let symbol = isExpanded ? "chevron.down" : "chevron.right"
        disclosureButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: isExpanded ? "Hide operation details" : "Show operation details"
        )
        jobScroll.isHidden = !(isExpanded && !displayedJobIDs.isEmpty)
    }

    /// Match the internal list-height constraint to the current state and, if the total bar
    /// height changed, ask the window controller to resize the bar to fit.
    func syncHeight() {
        jobListHeight.constant = listHeight
        let height = preferredHeight
        guard height != lastReportedHeight else { return }
        lastReportedHeight = height
        onPreferredHeightChanged?()
    }
}
