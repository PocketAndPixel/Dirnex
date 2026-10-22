import AppKit
import DirnexCore

/// One side of a comparison as the window receives it: the text, and what to call it.
struct CompareSource: Sendable {
    /// The file's name, over its pane.
    let name: String
    /// Where the file is, under its name.
    let detail: String
    let text: ComparedText
    /// The grammar its syntax is colored by, or `nil` for none.
    let language: SyntaxLanguage?
}

/// The compare window, which takes clicks and keys while another window is modal.
///
/// The Synchronize window is app-modal and opens comparisons, and a plain window opened from it
/// draws but takes no click or key until the Synchronize window closes. Probed 2026-10-22 with a
/// modal session: a plain window's click was dropped, this one's arrived, and with no session both
/// did (PLAN.md §M31 Slice 4).
final class CompareWindow: NSWindow {
    override var worksWhenModal: Bool { true }
}

/// Dirnex's own compare window (PLAN.md §M31 Slice 3): two files side by side, level row for row,
/// the changes marked, and the keyboard going from one change to the next.
///
/// Everything it shows is `TextComparison`'s, computed off the main thread together with each pane's
/// text and syntax colors; the main thread only sets the text. Changing an option computes it all
/// again and keeps the same line of the left file at the top.
@MainActor
final class CompareWindowController: NSWindowController, NSWindowDelegate {
    /// Windows on screen. A controller holds itself here until its window closes.
    private static var open: [CompareWindowController] = []

    let left: CompareSource
    let right: CompareSource
    private(set) var comparison: TextComparison?
    private(set) var changeKinds: [CompareChangeKind] = []
    private(set) var currentChange: Int?

    let toolbar = CompareToolbar()
    let banner = NSTextField(wrappingLabelWithString: "")
    let leftPane = ComparePaneView(side: .left)
    let rightPane = ComparePaneView(side: .right)
    let band = CompareBandView()
    let overview = CompareOverviewView()
    private(set) var sync: CompareScrollSync?
    var keyMonitor: Any?
    /// Watches for the end of the modal window this one was raised over (`+Modal`).
    var modalLevelObserver: (any NSObjectProtocol)?
    /// Bumped by every computation, so a slow earlier one cannot land over a newer one.
    private var generation = 0

    /// Open a window comparing `left` with `right`.
    @discardableResult
    static func present(left: CompareSource, right: CompareSource) -> CompareWindowController {
        let controller = CompareWindowController(left: left, right: right)
        open.append(controller)
        controller.raiseAboveModalWindow()
        controller.showWindow(nil)
        controller.compute(options: LineDiffOptions())
        return controller
    }

    init(left: CompareSource, right: CompareSource) {
        self.left = left
        self.right = right
        let window = CompareWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "\(left.name) ↔ \(right.name)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 320)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        if !window.setFrameUsingName(Self.frameName) {
            window.centerOnScreen()
        }
        window.setFrameAutosaveName(Self.frameName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static let frameName = "Dirnex.CompareWindow"

    // MARK: - Computing

    /// Everything one comparison shows, built off the main thread.
    struct Prepared: Sendable {
        let comparison: TextComparison
        let left: ComparisonPaneText
        let right: ComparisonPaneText
        let leftTokens: [SyntaxToken]
        let rightTokens: [SyntaxToken]
    }

    nonisolated static func prepare(
        left: CompareSource,
        right: CompareSource,
        options: LineDiffOptions,
        coloringLimit: Int
    ) -> Prepared {
        let comparison = TextComparison(left.text, right.text, options: options)
        let leftPane = ComparisonPaneText(comparison, side: .left)
        let rightPane = ComparisonPaneText(comparison, side: .right)
        func tokens(_ pane: ComparisonPaneText, _ language: SyntaxLanguage?) -> [SyntaxToken] {
            guard let language, pane.text.utf16.count <= coloringLimit else { return [] }
            return SyntaxHighlighter.tokens(in: pane.text, language: language)
        }
        return Prepared(
            comparison: comparison,
            left: leftPane,
            right: rightPane,
            leftTokens: tokens(leftPane, left.language),
            rightTokens: tokens(rightPane, right.language)
        )
    }

    /// Compare again under `options`, keeping the left file's line at the top where it was.
    func compute(options: LineDiffOptions) {
        generation += 1
        let generation = generation
        let keptLine = topLeftLine()
        let left = left
        let right = right
        let limit = CompareTextStyle.syntaxColoringLimit
        Task { [weak self] in
            let prepared = await BlockingWork.run {
                Self.prepare(left: left, right: right, options: options, coloringLimit: limit)
            }
            guard let self, generation == self.generation else { return }
            show(prepared, keepingLeftLine: keptLine)
        }
    }

    /// Put a computed comparison on screen.
    func show(_ prepared: Prepared, keepingLeftLine keptLine: Int?) {
        let comparison = prepared.comparison
        let isFirst = self.comparison == nil
        self.comparison = comparison
        changeKinds = CompareTextStyle.changeKinds(comparison)
        currentChange = nil
        leftPane.show(
            prepared.left,
            document: CompareTextStyle.document(
                for: prepared.left,
                rows: comparison.rows,
                tokens: prepared.leftTokens
            ),
            rows: comparison.rows,
            lineCount: comparison.leftLines.count
        )
        rightPane.show(
            prepared.right,
            document: CompareTextStyle.document(
                for: prepared.right,
                rows: comparison.rows,
                tokens: prepared.rightTokens
            ),
            rows: comparison.rows,
            lineCount: comparison.rightLines.count
        )
        band.changeRows = comparison.changeRows
        band.kinds = changeKinds
        band.current = nil
        overview.rowCount = comparison.rows.count
        overview.changeRows = comparison.changeRows
        overview.kinds = changeKinds
        banner.stringValue = Self.bannerText(for: comparison) ?? ""
        banner.isHidden = banner.stringValue.isEmpty
        toolbar.showCounter(current: nil, count: comparison.changeRows.count)
        window?.contentView?.layoutSubtreeIfNeeded()
        if isFirst, !comparison.changeRows.isEmpty {
            goToChange(0)
        } else if let keptLine, let row = comparison.rows.firstIndex(
            where: { ($0.left ?? -1) >= keptLine }
        ) {
            leftPane.textView.scroll(toRow: row, offset: 0, x: 0)
        }
        refreshScrolledViews()
    }

    /// The left file's line at the top of its pane, or the nearest one above it.
    private func topLeftLine() -> Int? {
        guard let comparison, let top = leftPane.textView.rowAtTop()?.row else { return nil }
        return comparison.rows[...top].last(where: { $0.left != nil })?.left
    }

    // MARK: - Moving between changes

    func goToChange(_ index: Int) {
        guard let comparison, comparison.changeRows.indices.contains(index) else { return }
        currentChange = index
        band.current = index
        toolbar.showCounter(current: index, count: comparison.changeRows.count)
        sync?.reveal(row: comparison.changeRows[index].lowerBound)
    }

    func goToNextChange() {
        guard let comparison else { return }
        let next: Int? = if let currentChange {
            currentChange + 1 < comparison.changeRows.count ? currentChange + 1 : nil
        } else {
            comparison.changeRows.firstIndex { $0.lowerBound >= (
                leftPane.textView.rowAtTop()?.row ?? 0
            ) }
        }
        guard let next else { return NSSound.beep() }
        goToChange(next)
    }

    func goToPreviousChange() {
        guard let comparison else { return }
        let previous: Int? = if let currentChange {
            currentChange > 0 ? currentChange - 1 : nil
        } else {
            comparison.changeRows.lastIndex { $0.lowerBound < (
                leftPane.textView.rowAtTop()?.row ?? 0
            ) }
        }
        guard let previous else { return NSSound.beep() }
        goToChange(previous)
    }

    /// Redraw what depends on what is on screen.
    func refreshScrolledViews() {
        band.needsDisplay = true
        overview.visibleRows = leftPane.textView.visibleRows()
        overview.needsDisplay = true
        leftPane.lineNumbers.needsDisplay = true
        rightPane.lineNumbers.needsDisplay = true
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        stopWatchingModalWindow()
        removeKeyMonitor()
        sync?.stop()
        Self.open.removeAll { $0 === self }
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.textColor = .secondaryLabelColor
        banner.isHidden = true
        for view in [leftPane, band, rightPane, overview] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        let column = NSStackView(views: [toolbar, banner, body])
        column.orientation = .vertical
        column.spacing = 0
        column.setHuggingPriority(.defaultLow, for: .vertical)
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toolbar.widthAnchor.constraint(equalTo: column.widthAnchor),
            body.widthAnchor.constraint(equalTo: column.widthAnchor),
            banner.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -12),
            leftPane.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            band.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            rightPane.leadingAnchor.constraint(equalTo: band.trailingAnchor),
            overview.leadingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            overview.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            band.widthAnchor.constraint(equalToConstant: CompareBandView.width),
            overview.widthAnchor.constraint(equalToConstant: CompareOverviewView.width),
            leftPane.widthAnchor.constraint(equalTo: rightPane.widthAnchor)
        ])
        for view in [leftPane, band, rightPane, overview] as [NSView] {
            view.topAnchor.constraint(equalTo: body.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor).isActive = true
        }
        window.contentView = content

        leftPane.setTitle(left.name, detail: left.detail)
        rightPane.setTitle(right.name, detail: right.detail)
        leftPane.textView.nextKeyView = rightPane.textView
        rightPane.textView.nextKeyView = leftPane.textView
        window.initialFirstResponder = leftPane.textView
        band.textView = leftPane.textView

        let sync = CompareScrollSync(left: leftPane, right: rightPane)
        sync.didScroll = { [weak self] in self?.refreshScrolledViews() }
        self.sync = sync
        toolbar.onPrevious = { [weak self] in self?.goToPreviousChange() }
        toolbar.onNext = { [weak self] in self?.goToNextChange() }
        toolbar.onOptionsChange = { [weak self] options in self?.compute(options: options) }
        overview.onJump = { [weak self] row in self?.jump(toRow: row) }
    }

    /// Show `row`, from the overview strip: no change is the current one after that.
    private func jump(toRow row: Int) {
        currentChange = nil
        band.current = nil
        toolbar.showCounter(current: nil, count: comparison?.changeRows.count ?? 0)
        sync?.reveal(row: row)
    }
}
