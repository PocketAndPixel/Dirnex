import AppKit

/// The one place a saved copy is routed to whichever kind of elsewhere it came from (PLAN.md §M4
/// write-back, §M21 Slice 10).
///
/// `EditedFileRegistry` detects the save and knows nothing about what to do with it; the two arms
/// live in `+ArchiveWriteBack` and `+WriteBackBatch`. Having the switch here rather than inside the
/// registry is what keeps the *detection* free of both endings — the registry is a watcher, and a
/// watcher that knew about archives and about `curl` would be two features wearing one type.
///
/// **The switch moved from the edit to the batch on 2026-09-01**, and that is the whole of what
/// changed here: saves are gathered first and split afterwards, so the two endings share one pacing
/// rule instead of each growing a copy of it. A script that rewrites forty files produces forty
/// saves whichever kind they are, and both endings were paying for that one at a time — the remote
/// one in forty uploads, the archive one in forty full repacks of the same container.
extension BrowserWindowController {
    /// A watched copy has been saved — put it in the next batch.
    ///
    /// Replacing rather than appending a second entry for the same copy: an editor that autosaves
    /// twice before a batch opens has one file to put back, and its *newer* bytes are the ones that
    /// should go.
    func offerWriteBack(_ edit: EditedFile) {
        pendingWriteBacks.removeAll { $0.temporaryURL == edit.temporaryURL }
        pendingWriteBacks.append(edit)
        guard !isGatheringWriteBacks else { return }
        isGatheringWriteBacks = true
        Task { await gatherWriteBacks() }
    }

    /// Carry one copy Dirnex itself has just written back where it came from, asking over `host`,
    /// and say whether it landed (PLAN.md §M33 Slice 4).
    ///
    /// The compare window's save of a server file or an archive member. The window writes the copy,
    /// and this is everything an editor's save of that copy gets: the re-`stat`, the prompt and the
    /// precondition and the queued upload, or the archive's question and its rewrite. The endings
    /// are the batch's own, run at once rather than gathered: the gathering paces saves a watcher
    /// noticed, and this one was pressed for and is waited on, which a batch has no way to answer.
    ///
    /// The questions go on `host`, the window the user pressed ⌘S in. The browser window can be
    /// behind it, or behind the Synchronize window the comparison was opened from.
    func writeBack(_ edit: EditedFile, askingOver host: NSWindow?) async -> Bool {
        // F4 may have this very copy open, and its watch would offer the window's write a second
        // time once the event arrives.
        editedFiles.acknowledgeWrite(to: edit.temporaryURL)
        switch edit.destination {
        case let .remoteFile(path):
            let landed = await runRemoteWriteBacks([(edit: edit, destination: path)], over: host)
            return landed.contains(path)
        case let .archiveMember(archivePath, innerDirectory):
            return await runArchiveWriteBacks(
                [PendingArchiveWriteBack(
                    edit: edit, archivePath: archivePath, innerDirectory: innerDirectory
                )],
                over: host
            )
        }
    }

    /// A write-back's failure, on `host` when one asked, else on the focused pane's window as
    /// before.
    func presentWriteBackFailure(message: String, detail: String, over host: NSWindow?) {
        guard let host else {
            focusedPanel.presentOperationFailure(message: message, detail: detail)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        alert.offerFullDiskAccessSettings()
        alert.beginSheetIfVisible(over: host)
    }
}
