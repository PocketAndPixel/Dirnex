import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The Name column fills the pane at every width, whatever width the tab's stored layout gave it
/// (`PanelViewController.fitNameColumnToPane`).
///
/// Reported 2026-11-02: narrowing the window left the left pane's Name column as wide as it was,
/// so Size was cut off at the pane's edge and Date was out of sight. That tab had stored Name at
/// 300 pt in a 386 pt pane, and through a live resize AppKit's first-column autoresizing leaves
/// columns wider than the pane alone. The other pane's columns fitted it, and it resized as it
/// should.
///
/// Each pane sits in a window that is never shown, because a pane in no window has no width to fit.
/// The window is resized inside the table's own live-resize calls: a programmatic resize refits
/// overflowing columns by itself, so without them the resize steps pass on the old code.
@MainActor
@Suite("Name column fills the pane", .serialized)
struct NameColumnFitTests {
    @MainActor
    private final class Hosted {
        let pane: PanelViewController
        private let window: NSWindow

        init(width: CGFloat) {
            // Empty, and written by nothing: a pane on the temp folder relisted it whenever any other
            // test in the run touched it.
            pane = PanelViewController(
                backend: CompositeBackend(local: LocalBackend()),
                restoration: nil,
                defaultPath: .local("/var/empty"),
                restorationKey: nil
            )
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = pane
            window.setContentSize(NSSize(width: width, height: 500))
            window.layoutIfNeeded()
        }

        /// Resize the window as dragging its edge does.
        func resize(to width: CGFloat) {
            pane.tableView.viewWillStartLiveResize()
            window.setContentSize(NSSize(width: width, height: 500))
            window.layoutIfNeeded()
            pane.tableView.viewDidEndLiveResize()
        }

        /// Give the active tab a stored layout and switch to it, as a tab switch or a relaunch does.
        func apply(nameWidth: Double) {
            pane.tabs[pane.activeTabIndex].columnLayout = [
                ColumnLayout(id: "name", width: nameWidth),
                ColumnLayout(id: "size", width: 90),
                ColumnLayout(id: "date", width: 131)
            ]
            pane.applyColumnLayout(for: pane.tabs[pane.activeTabIndex])
        }

        var paneWidth: CGFloat { pane.scrollView.contentView.bounds.width }

        var nameWidth: CGFloat {
            let index = pane.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            return pane.tableView.tableColumns[index].width
        }

        /// What the columns take, with the spacing `NSTableView` adds after each one.
        var columnsWidth: CGFloat {
            let spacing = pane.tableView.intercellSpacing.width
            return pane.tableView.tableColumns.reduce(0) { $0 + $1.width + spacing }
        }

        var fillsPane: Bool { abs(columnsWidth - paneWidth) < 0.5 }

        func close() {
            pane.watcher = nil
            window.contentViewController = nil
            window.close()
        }
    }

    @Test("a stored Name wider than the pane is fitted, and then follows the window both ways")
    func widerThanPane() {
        let hosted = Hosted(width: 800)
        defer { hosted.close() }

        hosted.apply(nameWidth: 900)
        #expect(hosted.fillsPane)

        let fitted = hosted.nameWidth
        hosted.resize(to: 600)
        #expect(hosted.fillsPane)
        #expect(hosted.nameWidth < fitted)

        hosted.resize(to: 1000)
        #expect(hosted.fillsPane)
        #expect(hosted.nameWidth > fitted)
    }

    @Test("a stored Name narrower than the pane is fitted, and then follows the window both ways")
    func narrowerThanPane() {
        let hosted = Hosted(width: 1000)
        defer { hosted.close() }

        hosted.apply(nameWidth: 120)
        #expect(hosted.fillsPane)
        #expect(hosted.nameWidth > 120)

        let fitted = hosted.nameWidth
        hosted.resize(to: 1200)
        #expect(hosted.fillsPane)
        #expect(hosted.nameWidth > fitted)

        hosted.resize(to: 700)
        #expect(hosted.fillsPane)
        #expect(hosted.nameWidth < fitted)
    }

    @Test("removing the size bar from a pane at Name's floor gives Name back only what fits")
    func sizeBarRefund() {
        // The bar is paid for out of Name, which stops at its `minWidth`. Refunding the bar's full
        // width on removal then made Name wider than it had been, and the table overflowed again.
        let hosted = Hosted(width: 800)
        defer { hosted.close() }
        hosted.apply(nameWidth: 300)
        hosted.resize(to: 440)
        #expect(hosted.fillsPane)

        hosted.pane.setSizeBarColumnInstalled(true)
        #expect(hosted.nameWidth == PanelViewController.Column.name.minWidth)

        hosted.pane.setSizeBarColumnInstalled(false)
        #expect(hosted.fillsPane)
    }
}
