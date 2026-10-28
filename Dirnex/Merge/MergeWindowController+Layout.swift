import AppKit
import DirnexCore

/// Building the merge window's views (PLAN.md §M34 Slice 3): the toolbar, the banner, then Base,
/// Yours, Result and Theirs with a band between each two and the overview strip at the right edge.
/// The base and its band are hidden until Show Base, and Yours then starts at the window's edge.
extension MergeWindowController {
    /// Lay the views out in `window` and wire each control to the controller. Called once, from
    /// `init`.
    func buildContent(in window: NSWindow) {
        let content = NSView()
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.textColor = .secondaryLabelColor
        banner.isHidden = true
        let row: [NSView] = [
            basePane, baseBand, yoursPane, yoursBand, resultPane, theirsBand, theirsPane, overview
        ]
        for view in row {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
            view.topAnchor.constraint(equalTo: body.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor).isActive = true
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
            // While hidden, the base sits under Yours, the same width, so nothing has to give way.
            basePane.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            baseBand.leadingAnchor.constraint(equalTo: basePane.trailingAnchor),
            yoursBand.leadingAnchor.constraint(equalTo: yoursPane.trailingAnchor),
            resultPane.leadingAnchor.constraint(equalTo: yoursBand.trailingAnchor),
            theirsBand.leadingAnchor.constraint(equalTo: resultPane.trailingAnchor),
            theirsPane.leadingAnchor.constraint(equalTo: theirsBand.trailingAnchor),
            overview.leadingAnchor.constraint(equalTo: theirsPane.trailingAnchor),
            overview.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            overview.widthAnchor.constraint(equalToConstant: CompareOverviewView.width),
            basePane.widthAnchor.constraint(equalTo: yoursPane.widthAnchor),
            resultPane.widthAnchor.constraint(equalTo: yoursPane.widthAnchor),
            theirsPane.widthAnchor.constraint(equalTo: yoursPane.widthAnchor)
        ])
        for band in bands {
            band.widthAnchor.constraint(equalToConstant: CompareBandView.width).isActive = true
            // The panes are level, so any one of them gives every band its rows' positions.
            band.textView = yoursPane.textView
        }
        yoursAfterBase = yoursPane.leadingAnchor.constraint(equalTo: baseBand.trailingAnchor)
        yoursAtEdge = yoursPane.leadingAnchor.constraint(equalTo: body.leadingAnchor)
        window.contentView = content

        // Yours leads, so a pane appearing is brought level with what was already on screen.
        let sync = CompareScrollSync(panes: [yoursPane, resultPane, theirsPane, basePane])
        sync.didScroll = { [weak self] in self?.refreshScrolledViews() }
        self.sync = sync
        setBaseShown(false)
        window.initialFirstResponder = resultPane.textView
        resultPane.holdsKeyboard = true
        for (column, pane) in panes {
            pane.textView.onFocus = { [weak self] in self?.paneTookKeyboard(column) }
        }

        toolbar.onPrevious = { [weak self] in self?.goToPreviousConflict() }
        toolbar.onNext = { [weak self] in self?.goToNextConflict() }
        toolbar.onTake = { [weak self] choice in self?.take(choice) }
        toolbar.onShowBase = { [weak self] shown in self?.setBaseShown(shown) }
        toolbar.onSave = { [weak self] in self?.saveFromKey() }
        overview.onJump = { [weak self] row in self?.jump(toRow: row) }
        refreshControls()
    }

    /// Whether the base pane is on screen.
    var isBaseShown: Bool {
        !basePane.isHidden
    }

    /// Show or hide the base, at the left edge, level with the other panes (Show Base, ⌥⌘B).
    func setBaseShown(_ shown: Bool) {
        basePane.isHidden = !shown
        baseBand.isHidden = !shown
        yoursAtEdge?.isActive = !shown
        yoursAfterBase?.isActive = shown
        toolbar.showBase.state = shown ? .on : .off
        // Tab goes round the panes on screen, left to right, then along the toolbar, as in the compare
        // window.
        let order = (shown ? [basePane] : []) + [yoursPane, resultPane, theirsPane]
        let loop = order.map { $0.textView as NSView } + toolbar.keyViews
        for (index, view) in loop.enumerated() {
            view.nextKeyView = loop[(index + 1) % loop.count]
        }
        if !shown, window?.firstResponder === basePane.textView {
            window?.makeFirstResponder(resultPane.textView)
        }
        // The toolbar can hold the keyboard with the base marked, as it does after Space on Show Base.
        if !shown, basePane.holdsKeyboard {
            paneTookKeyboard(.result)
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        if shown { sync?.align() }
        refreshScrolledViews()
    }
}
