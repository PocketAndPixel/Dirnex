import AppKit
import DirnexCore

/// Building the compare window's views (PLAN.md §M31 Slice 3): the toolbar, the banner, the two
/// panes with the band between them and the overview strip, and the wiring from each control to
/// the controller. Split out of the controller when Edit Left and Edit Right (PLAN.md §M33 Slice 5)
/// took it past the type-body ceiling.
extension CompareWindowController {
    /// Lay the views out in `window` and wire each control to the controller. Called once, from
    /// `init`.
    func buildContent(in window: NSWindow) {
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
        toolbar.onCopy = { [weak self] side in self?.copyCurrentChange(to: side) }
        toolbar.copy.isHidden = !allowsCopies
        for pane in [leftPane, rightPane] {
            pane.editButton.isHidden = !allowsCopies
            pane.onEdit = { [weak self, side = pane.side] in self?.editFile(on: side) }
        }
        overview.onJump = { [weak self] row in self?.jump(toRow: row) }
    }
}
