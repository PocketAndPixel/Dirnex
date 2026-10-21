import AppKit
import DirnexCore

/// The window's half of a pane closing a tab: it keeps the tab so ⇧⌘T can bring it back.
///
/// Its own protocol, which `PanelHost` inherits, rather than one more requirement in that list: the
/// list lives in `PanelViewController.swift`, which sits at SwiftLint's file-length ceiling, and the
/// concept is separate enough to stand on its own (docs/NOTES.md ▸ Lint ceilings and file splitting).
@MainActor
protocol ClosedTabHost: AnyObject {
    /// `tab` was closed in `panel`, where it sat at `index`. Not called for a tab moved to the other
    /// pane, which is still open, nor for the last tab, whose ⌘W closes the window instead.
    func panelDidCloseTab(_ tab: PanelTab, at index: Int, in panel: PanelViewController)
}

/// Reopen Closed Tab (⇧⌘T): the tabs closed in this window, newest first, each back into the pane
/// and the place it left.
///
/// A closed tab is kept **as the tab itself**, not as a snapshot of it, which is what moving a tab
/// to the other pane already does (`PanelViewController+TabMoves`). So it comes back with everything
/// it had: its back/forward trail, sort, columns, tree, cursor and marks, size bars, and even a
/// search's results, which a written-down tab cannot hold. Its listing is the one it had when it
/// closed, shown at once and re-read behind it, exactly as switching to a tab that sat in the
/// background (`activateTab`). Held for this run only, and gone with the window.
extension BrowserWindowController: ClosedTabHost {
    func panelDidCloseTab(_ tab: PanelTab, at index: Int, in panel: PanelViewController) {
        closedTabs.push(tab, from: side(of: panel), at: index)
    }

    /// ⇧⌘T — put the last closed tab back where it was and focus it there, whichever pane has the
    /// focus now.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let entry = closedTabs.popLast() else { return }
        let pane = entry.pane == .left ? leftPanel : rightPanel
        pane.reopen(entry.tab, atSlot: entry.slot)
    }

    /// Whether ⇧⌘T has anything to bring back, for the File menu.
    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// Forget the closed tabs standing on a volume that has just gone — a vault locked, a disk
    /// ejected. Reopening one would land on a folder that is not there, and for a vault its names are
    /// exactly what locking it was meant to put away.
    func forgetClosedTabs(onUnmountedVolumeAt mountPoint: VFSPath) {
        closedTabs.forget { $0.panel.path.isSelfOrDescendant(of: mountPoint) }
    }

    private func side(of panel: PanelViewController) -> PaneSide {
        panel === rightPanel ? .right : .left
    }
}
