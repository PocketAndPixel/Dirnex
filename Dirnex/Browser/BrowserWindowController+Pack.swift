import AppKit
import DirnexCore

/// Where a finished encrypted pack's answer reaches the user (PLAN.md §M19 Slice 2).
///
/// It lands on the *window*, not the pane, for the same reason a checksum's report does: the job
/// outlives the gesture that started it. AES-256 over a folder of photographs is minutes, during
/// which the user can change tabs, switch panes or start something else — and the answer must still
/// arrive, once, over whatever is on screen then.
///
/// The two outcomes get deliberately different surfaces, following the checksum precedent. A
/// **written archive** is a file the user can see in the pane, so it gets a status line rather than
/// a modal saying "done" over a result already visible. A **failure** interrupts, because nothing
/// was written and the pane looks exactly as it did before — there is no other way to find out.
extension BrowserWindowController {
    func presentPackOutcome(of report: OperationReport) {
        switch report.pack {
        case let .created(summary):
            presentPackSuccess(summary)
        case let .failed(error):
            presentPackFailure(error)
        case nil:
            // A cancelled pack. It left nothing behind — the writer builds under a temporary name
            // and only renames on success — and the user is the one who cancelled it, so there is
            // nothing to tell them that the queue bar disappearing has not already said.
            break
        }
    }

    private func presentPackSuccess(_ summary: PackSummary) {
        // The archive lands in the pane the pack *targeted*, which is the one the user is not
        // standing in — Pack writes into the other pane, like F5. So the pane to re-list is the one
        // showing the archive's own directory, never `focusedPanel`: selecting there asks the source
        // pane to put its cursor on a file it does not contain, which fails silently and leaves the
        // new archive sitting unselected in the pane that does. (The neighbouring checksum outcome
        // reads `focusedPanel` correctly, because a manifest is written beside the files it covers.)
        paneShowing(summary.archive.parent)?.refreshCurrentDirectory(selecting: summary.archive)
        let name = summary.archive.lastComponent
        let size = ByteCountFormatter.string(
            fromByteCount: summary.byteSize,
            countStyle: .file
        )
        // Name and size, and no item count: the count only repeats the selection the user just
        // made, while the size is the one fact that is new. It also keeps this out of the
        // multi-argument plural machinery in fourteen languages for a number nobody reads.
        focusedPanel.showTransientStatus(
            summary.encryption.isEncrypted
                ? String(
                    localized: "Encrypted “\(name)” — \(size)",
                    comment: """
                    Status after writing an encrypted archive; %1$@ is its name and %2$@ its size.
                    """
                )
                : String(
                    localized: "Packed “\(name)” — \(size)",
                    comment: "Status after writing an archive; %1$@ is its name and %2$@ its size."
                )
        )
    }

    /// The pane currently showing `directory`, the **inactive** one first since that is what a pack
    /// targets. `nil` when neither does — the user navigated both panes away while the job ran, and
    /// there is then nothing to re-list, which is an answer rather than a failure.
    private func paneShowing(_ directory: VFSPath?) -> PanelViewController? {
        guard let directory else { return nil }
        let candidates = [panelCounterpart(of: focusedPanel), focusedPanel].compactMap { $0 }
        return candidates.first { $0.panel.path == directory }
    }

    /// Nothing was written, so this interrupts.
    ///
    /// The sentence comes from the catalog rather than the core's English
    /// (`LocalizedCatalog.sentence(for:)`): it reaches the screen through a return value, where a
    /// literal would render English under a translated title at the moment something failed.
    private func presentPackFailure(_ error: EncryptedArchiveError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Couldn’t create the archive",
            comment: "Title of the alert shown when an encrypted pack wrote nothing."
        )
        alert.informativeText = LocalizedCatalog.sentence(for: error)
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
