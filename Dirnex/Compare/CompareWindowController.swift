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

    /// The file on the left, and the one on the right. Swap Sides exchanges them.
    private(set) var left: CompareSource
    private(set) var right: CompareSource
    private(set) var comparison: TextComparison?
    private(set) var changeKinds: [CompareChangeKind] = []
    /// The change the band marks and the counter names, or `nil` for none (`+Changes`).
    var currentChange: Int?

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
        controller.place()
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
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 320)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Where the user last left the window, else centered on the browser window: the dialogs'
    /// placement (`DialogWindowPlacement`). The window is resizable, so its size comes back too.
    /// Done in `present` rather than `init`, so a window a test builds saves no frame.
    private func place() {
        guard let window else { return }
        let browser = (NSApp.delegate as? AppDelegate)?.activeBrowserWindowController?.window
        DialogWindowPlacement.place(window, key: "CompareWindow", centeredOver: browser)
    }

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
        compute(options: options, keepingLeftLine: topLine(on: .left))
    }

    /// Compare again under `options`, then put the left file's `keptLine` at the top.
    private func compute(options: LineDiffOptions, keepingLeftLine keptLine: Int?) {
        generation += 1
        let generation = generation
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
        // Only the newest computation is shown, and it read the sides as they stand now, so a swap
        // renames the panes together with their text rather than ahead of it.
        showTitles()
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

    /// One file's line at the top of the panes, or the nearest one above it.
    private func topLine(on side: ComparisonPaneText.Side) -> Int? {
        guard let comparison, let top = leftPane.textView.rowAtTop()?.row else { return nil }
        let rows = comparison.rows[...top]
        return switch side {
        case .left: rows.last(where: { $0.left != nil })?.left
        case .right: rows.last(where: { $0.right != nil })?.right
        }
    }

    /// The window's title and each pane's header, for the sides as they stand.
    private func showTitles() {
        window?.title = "\(left.name) ↔ \(right.name)"
        leftPane.setTitle(left.name, detail: left.detail)
        rightPane.setTitle(right.name, detail: right.detail)
    }

    // MARK: - Swapping sides

    /// Put the right file on the left and the left file on the right (⌘U).
    ///
    /// The colors read the left side as before and the right as after (`CompareColors`), and the
    /// order a pair opens in is a guess: a marked pair goes older-first, a cursor pair as the panes
    /// stand. This puts a wrong guess right without going back to the panes. The pair is compared
    /// again rather than mirrored, so the window shows what opening it the other way round would,
    /// and the line at the top stays at the top, now in the left pane.
    func swapSides() {
        let keptLine = topLine(on: .right)
        (left, right) = (right, left)
        compute(options: toolbar.options, keepingLeftLine: keptLine)
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

        showTitles()
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
        toolbar.onSwap = { [weak self] in self?.swapSides() }
        overview.onJump = { [weak self] row in self?.jump(toRow: row) }
    }
}
