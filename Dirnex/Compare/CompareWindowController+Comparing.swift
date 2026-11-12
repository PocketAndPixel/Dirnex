import AppKit
import DirnexCore

/// How a window opened before its files have been read gets at them (PLAN.md §M37 Slice 3).
struct CompareReading {
    /// Read both files, asking the closure it is given whether to stop. Blocking; it runs off the main
    /// thread.
    let read: @Sendable (@escaping @Sendable () -> Bool)
        -> Result<(CompareSource, CompareSource), CompareReadFailure>
    /// The files turned out not to be readable as text. The window has closed by then.
    let failed: @MainActor (CompareReadFailure) -> Void
}

/// Reading and comparing, which run off the main thread (PLAN.md §M31 Slice 3 and §M37 Slice 3).
///
/// A pair of ordinary files is read first and the window then opens on it. A pair past the size that
/// reads in a moment opens the window first, on stand-ins that name the files and hold no lines, so
/// nothing sits unanswered for the many seconds a file of gigabytes takes.
///
/// A comparison that runs for more than a moment says so in the toolbar and offers Stop. Stop empties
/// the panes rather than leaving what they showed, since by then the sides may have been swapped or
/// a copy applied, and what they showed would be a comparison of something else.
extension CompareWindowController {
    /// How long a comparison runs before the window says so: long enough that an ordinary pair never
    /// flashes it.
    static let usualComparingDelay = Duration.milliseconds(200)

    /// Whether a read or a comparison is running.
    var isComparing: Bool {
        runningStop != nil
    }

    /// Compare again under `options`, keeping the left file's line at the top where it was.
    func compute(options: LineDiffOptions) {
        let kept = topLine(on: .left).map { KeptLine(side: .left, line: $0) }
        compute(options: options, keeping: kept)
    }

    /// Compare the sides as they stand under `options`. Once that lands, the change `select` picks
    /// is the current one, or failing that `kept` is at the top. Nothing happens while the sides are
    /// still being read: the read compares them under the options as they then stand.
    func compute(
        options: LineDiffOptions,
        keeping kept: KeptLine?,
        selecting select: (@MainActor (TextComparison) -> Int?)? = nil
    ) {
        guard reading == nil else { return }
        let stop = beginComparing()
        let generation = generation
        let revision = sidesRevision
        let saves = savesLanded
        let left = left
        let right = right
        let limit = CompareTextStyle.syntaxColoringLimit
        let preparer = preparer
        Task { [weak self] in
            let prepared = await BlockingWork.run {
                try? preparer(left, right, options, limit) { stop.isCancelled }
            }
            guard let self, generation == self.generation else { return }
            finishComparing()
            guard let prepared else { return }
            comparedRevision = revision
            show(prepared, keeping: kept, selecting: select)
            if saves != savesLanded { refreshEditedMarks() }
        }
    }

    /// Put a computed comparison on screen.
    func show(
        _ prepared: Prepared,
        keeping kept: KeptLine? = nil,
        selecting select: (@MainActor (TextComparison) -> Int?)? = nil
    ) {
        let comparison = prepared.comparison
        let isFirst = self.comparison == nil
        self.comparison = comparison
        // Only the newest computation is shown, and it read the sides as they stand now, so a swap
        // renames the panes together with their text rather than ahead of it.
        showTitles(edited: (prepared.leftEdited, prepared.rightEdited))
        changeKinds = prepared.changeKinds
        currentChange = nil
        for (side, pane) in panes {
            pane.show(
                side == .left ? prepared.left : prepared.right,
                document: side == .left ? prepared.leftDocument.text : prepared.rightDocument.text,
                fills: side == .left ? prepared.leftFills : prepared.rightFills,
                endingDiffers: prepared.endingDiffers,
                lineCount: side == .left ? comparison.leftLines.count : comparison.rightLines.count
            )
        }
        band.changeRows = comparison.changeRows
        band.kinds = changeKinds
        band.current = nil
        overview.rowCount = comparison.rows.count
        overview.changeRows = comparison.changeRows
        overview.kinds = changeKinds
        banner.stringValue = Self.bannerText(for: comparison, readOnly: readOnlySides) ?? ""
        banner.isHidden = banner.stringValue.isEmpty
        toolbar.showCounter(current: nil, count: comparison.changeRows.count)
        window?.contentView?.layoutSubtreeIfNeeded()
        let selected = isFirst ? (comparison.changeRows.isEmpty ? nil : 0) : select?(comparison)
        if let selected {
            goToChange(selected)
        } else if let kept, let row = comparison.rows.firstIndex(
            where: { ((kept.side == .left ? $0.left : $0.right) ?? -1) >= kept.line }
        ) {
            leftPane.textView.scroll(toRow: row, offset: 0, x: 0)
        }
        refreshCopyControls()
        refreshScrolledViews()
    }

    // MARK: - Reading

    /// Read the two files with the window up, then compare them.
    func startReading() {
        guard let reading else { return }
        let stop = beginComparing()
        toolbar.showComparing()
        refreshCopyControls()
        let generation = generation
        Task { [weak self] in
            let outcome = await BlockingWork.run { reading.read { stop.isCancelled } }
            guard let self, generation == self.generation else { return }
            finishComparing()
            finishReading(outcome, failed: reading.failed)
        }
    }

    private func finishReading(
        _ outcome: Result<(CompareSource, CompareSource), CompareReadFailure>,
        failed: @MainActor (CompareReadFailure) -> Void
    ) {
        switch outcome {
        case let .success((readLeft, readRight)):
            reading = nil
            left = readLeft
            right = readRight
            sidesRevision += 1
            startWatchingFiles()
            compute(options: toolbar.options, keeping: nil)
        case let .failure(failure):
            window?.close()
            failed(failure)
        }
    }

    // MARK: - Stopping

    /// Stop what is running, here and now: whatever it would still have handed back is not shown.
    func stopComparing() {
        guard isComparing else { return }
        abandonComparing()
        forgetComparison()
        toolbar.showStopped()
    }

    /// Run again what Stop ended.
    func compareAgain() {
        if reading != nil {
            startReading()
        } else {
            compute(options: toolbar.options)
        }
    }

    /// Ask the running read or comparison to end, and see that nothing it leaves lands.
    func abandonComparing() {
        runningStop?.isCancelled = true
        runningStop = nil
        generation += 1
    }

    /// Start a run in place of any before it, and say so in the toolbar if it goes on for a moment.
    private func beginComparing() -> CancellationFlag {
        abandonComparing()
        let stop = CancellationFlag()
        runningStop = stop
        let generation = generation
        let delay = comparingDelay
        if toolbar.comparingState == .stopped { toolbar.showComparing() }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, generation == self.generation, isComparing else { return }
            toolbar.showComparing()
        }
        return stop
    }

    private func finishComparing() {
        runningStop = nil
        toolbar.showFinishedComparing()
    }

    /// Empty the panes, and everything drawn from them.
    private func forgetComparison() {
        comparison = nil
        changeKinds = []
        currentChange = nil
        let nothing = ComparisonPaneText(lines: [], rows: [])
        for (_, pane) in panes {
            pane.show(nothing, document: NSAttributedString(), fills: [], lineCount: 0)
        }
        band.changeRows = []
        band.kinds = []
        band.current = nil
        overview.rowCount = 0
        overview.changeRows = []
        overview.kinds = []
        banner.stringValue = ""
        banner.isHidden = true
        showTitles()
        refreshEditedMarks()
        refreshCopyControls()
        refreshScrolledViews()
    }
}

/// Preparing a comparison for the screen, which runs off the main thread and reads nothing of the
/// controller's.
extension CompareWindowController {
    /// A pane's colored text, made off the main thread and only read after that.
    struct PaneDocument: @unchecked Sendable {
        let text: NSAttributedString
    }

    /// Everything one comparison shows, built off the main thread.
    struct Prepared: Sendable {
        let comparison: TextComparison
        let left: ComparisonPaneText
        let right: ComparisonPaneText
        let leftDocument: PaneDocument
        let rightDocument: PaneDocument
        let leftFills: [AlignedRowFill]
        let rightFills: [AlignedRowFill]
        let changeKinds: [CompareChangeKind]
        let endingDiffers: [Bool]
        /// Whether each side's lines differ from its file as read, which takes a pass over both.
        let leftEdited: Bool
        let rightEdited: Bool
    }

    /// A file's line to keep at the top when a comparison lands, on the side it will be on then.
    struct KeptLine {
        let side: ComparisonPaneText.Side
        let line: Int
    }

    /// Turns the two sides into what the window shows, or stops when its last argument says so.
    typealias Preparer = @Sendable (
        CompareSource,
        CompareSource,
        LineDiffOptions,
        Int,
        @escaping @Sendable () -> Bool
    ) throws(CancellationError) -> Prepared

    nonisolated static let livePreparer: Preparer = { left, right, options, limit, isCancelled in
        try prepare(
            left: left,
            right: right,
            options: options,
            coloringLimit: limit,
            isCancelled: isCancelled
        )
    }

    nonisolated static func prepare(
        left: CompareSource,
        right: CompareSource,
        options: LineDiffOptions,
        coloringLimit: Int,
        isCancelled: () -> Bool = { false }
    ) throws(CancellationError) -> Prepared {
        let comparison = try TextComparison(
            left.document,
            right.document,
            options: options,
            isCancelled: isCancelled
        )
        let leftPane = try ComparisonPaneText(comparison, side: .left, isCancelled: isCancelled)
        let rightPane = try ComparisonPaneText(comparison, side: .right, isCancelled: isCancelled)
        func document(_ pane: ComparisonPaneText, _ language: SyntaxLanguage?) -> PaneDocument {
            var tokens: [SyntaxToken] = []
            if let language, pane.text.utf16.count <= coloringLimit {
                tokens = SyntaxHighlighter.tokens(in: pane.text, language: language)
            }
            return PaneDocument(
                text: CompareTextStyle.document(for: pane, rows: comparison.rows, tokens: tokens)
            )
        }
        let leftDocument = document(leftPane, left.language)
        guard !isCancelled() else { throw CancellationError() }
        let rightDocument = document(rightPane, right.language)
        guard !isCancelled() else { throw CancellationError() }
        return Prepared(
            comparison: comparison,
            left: leftPane,
            right: rightPane,
            leftDocument: leftDocument,
            rightDocument: rightDocument,
            leftFills: CompareTextStyle.fills(for: .left, rows: comparison.rows),
            rightFills: CompareTextStyle.fills(for: .right, rows: comparison.rows),
            changeKinds: CompareTextStyle.changeKinds(comparison),
            endingDiffers: comparison.rows.map(\.lineEndingsDiffer),
            leftEdited: left.document.isEdited,
            rightEdited: right.document.isEdited
        )
    }
}
