import AppKit
import DirnexCore

/// The pane's half of following a link in Quick View (PLAN.md §M39 ▸ Slice 5): a link to another
/// file moves this pane's cursor onto it, entering the folder it is in when that is elsewhere, and the
/// preview follows the cursor as it does on every step. The pane's own Back is the way back.
extension PanelViewController {
    /// Where the file under the cursor is on its own backend — what a rendered page's links lead
    /// from, and the half of the preview's identity that its URL cannot carry for a server's file or
    /// an archive member, which are shown from local copies. `nil` on the `..` row or in an empty
    /// directory, like ``quickViewSourceURL``.
    var quickViewSourceLocation: VFSPath? {
        guard !cursorOnParentRow, let entry = panel.currentEntry else { return nil }
        return entry.path
    }

    /// Put the cursor on `target`.
    ///
    /// A target this listing shows takes a cursor step and nothing more: the common link is to a
    /// sibling, and over a server a second listing of the folder on screen would be a request for
    /// nothing. Anything else is asked about first, so a link to a file that is not there says so
    /// rather than leaving the pane in a folder with its cursor on whatever sorts first. A results
    /// listing — search, Recents, the Trash — opens the target's folder in a new tab, which keeps the
    /// results, as opening a folder from one does (`openResultDirectory`).
    func revealLinkTarget(_ target: VFSPath) {
        focusTable()
        if panel.displayedIndex(ofID: target) != nil {
            moveCursor(onto: target)
            return
        }
        let backend = backend
        Task {
            let found = await BlockingWork.run { Result { try backend.stat(at: target) } }
            switch found {
            case .success:
                guard let folder = target.parent else {
                    navigate(to: target)
                    return
                }
                if isResultsListing { openInNewTab(folder) }
                navigate(to: folder, focus: target)
            case let .failure(error):
                if let refusal = error as? VFSError, case .notFound = refusal {
                    presentMissingLinkTarget(target)
                } else {
                    presentLoadFailure(error, path: target)
                }
            }
        }
    }

    /// Say that the file a link names is not where the link says. The target always has a folder:
    /// a backend's root, the one place without one, is never missing.
    private func presentMissingLinkTarget(_ target: VFSPath) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Can’t follow this link")
        let name = target.lastComponent
        let folder = (target.parent ?? target).displayName
        alert.informativeText = String(localized: "There’s no “\(name)” in “\(folder)”.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.enableEscapeToCancel()
        alert.beginSheetIfVisible(over: viewIfLoaded?.window)
    }
}
