import AppKit
import DirnexCore

/// Compare By Contents in Dirnex's own window (PLAN.md §M31 Slice 4), from the pane's side.
/// Everything before this point — the download, the pre-scan, identical files — is shared with the
/// external tools in `PanelViewController+Compare`; the reading is `CompareOpener`'s.
extension PanelViewController {
    /// Open the window on the pair, naming each file where the user knows it rather than the copy
    /// that was read.
    func openCompareWindow(_ left: CompareFile, with right: CompareFile) {
        CompareOpener.openWindow(
            left,
            detail: compareDetail(for: left.origin),
            right,
            detail: compareDetail(for: right.origin)
        ) { [weak self] detail in
            self?.clearTransientStatus()
            self?.presentCompareFailure(message: CompareOpener.failureTitle, detail: detail)
        }
    }

    /// Where a file lives, as a pane's header says it: Copy Path's text, with the server's name in
    /// front for a file on a server (`oleg@nas:/srv/notes.txt`, the way `scp` writes it).
    ///
    /// Copy Path writes a server file's bare path, which is right for pasting into a shell on that
    /// server and wrong here: seen live in PLAN.md §M31 Slice 5, a server file and a local one read
    /// as two local paths side by side. The name is the path bar's own root crumb.
    func compareDetail(for origin: VFSPath) -> String {
        let path = copyPathText(for: origin)
        guard origin.backend.isRemoteConnection, let server = origin.backendRootTitle else { return path }
        return "\(server):\(path)"
    }

    /// A pair too large for the window, refused before anything is read. The window reads a file
    /// whole or not at all, and its limit is the pre-scan's, so there is nothing to ask.
    func refuseOversizedCompare(byteSize: Int64) {
        clearTransientStatus()
        presentCompareFailure(
            message: String(
                localized: "These files are large (\(FileFormatting.byteString(byteSize))).",
                comment: "Oversized-compare warning title; %@ is a formatted byte size."
            ),
            detail: CompareOpener.limitDetail(ByteComparator.prescanByteLimit)
        )
    }

    /// A compare alert, on whatever is in front of the pane: the Synchronize window compares too,
    /// and an alert on the browser window behind it could not be clicked (`alertHostWindow`).
    func presentCompareFailure(message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        if let window = alertHostWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
