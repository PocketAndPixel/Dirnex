import AppKit

/// How the window's views are stacked: the queue bar under the sidebar-and-panes split, and the
/// function bar under the panes only.
///
/// Split out of `BrowserWindowController` when that file reached SwiftLint's 500-line ceiling —
/// by concept rather than to shave lines, since building the container hierarchy is a job on its
/// own and shares nothing with focus routing or the `PanelHost` conformance. The extension is
/// internal rather than `private` because Swift's `private` does not cross files; `queueBarHeight`
/// widened for the same reason.
extension BrowserWindowController {
    /// Stack the sidebar-and-panes split over the queue bar, both full width. The function bar is
    /// *not* here — it lives inside the panes column (`makePaneColumnController`) so it aligns with
    /// the panes rather than spanning under the sidebar. `setQueueBar(visible:)` collapses the queue
    /// bar to zero while idle, handing its height back to the panes.
    func makeContainerViewController() -> NSViewController {
        let container = NSViewController()
        container.view = NSView()
        container.addChild(splitViewController)

        let splitView = splitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        queueBar.translatesAutoresizingMaskIntoConstraints = false
        queueBar.isHidden = true
        container.view.addSubview(splitView)
        container.view.addSubview(queueBar)

        queueBarHeight = queueBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: queueBar.topAnchor),
            queueBar.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            queueBar.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            queueBar.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            queueBarHeight
        ])
        return container
    }

    /// The right-hand column of the outer sidebar split: the pane stack (two panes over the
    /// terminal drawer) with the function-key bar pinned along its bottom. Wrapping them together
    /// as the split's second item is what keeps the bar off the sidebar — the sidebar is the split's
    /// *first* item and stays full height beside this whole column. The window controller owns
    /// `functionBarHeight` and collapses it to zero when the feature is off.
    func makePaneColumnController() -> NSViewController {
        let column = NSViewController()
        column.view = NSView()
        column.addChild(paneStackSplitViewController)

        let paneStack = paneStackSplitViewController.view
        paneStack.translatesAutoresizingMaskIntoConstraints = false
        functionBar.translatesAutoresizingMaskIntoConstraints = false
        functionBar.isHidden = true
        column.view.addSubview(paneStack)
        column.view.addSubview(functionBar)

        functionBarHeight = functionBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            paneStack.topAnchor.constraint(equalTo: column.view.topAnchor),
            paneStack.leadingAnchor.constraint(equalTo: column.view.leadingAnchor),
            paneStack.trailingAnchor.constraint(equalTo: column.view.trailingAnchor),
            paneStack.bottomAnchor.constraint(equalTo: functionBar.topAnchor),
            functionBar.leadingAnchor.constraint(equalTo: column.view.leadingAnchor),
            functionBar.trailingAnchor.constraint(equalTo: column.view.trailingAnchor),
            functionBar.bottomAnchor.constraint(equalTo: column.view.bottomAnchor),
            functionBarHeight
        ])
        return column
    }
}
