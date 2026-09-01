import AppKit
import DirnexCore

/// Putting several edited members back into their archives — **one rewrite per archive**
/// (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// The archive half of the write-back batch, and the half whose old shape cost the most. A rewrite
/// is extract-everything → mutate → repack → atomic swap, so it is proportional to the *container*
/// and not to what changed in it: forty members saved one at a time meant forty full passes over
/// the same archive, each one extracting and re-compressing everything the previous had just
/// written, and forty sheets in front of them. Grouped, it is one pass and one question per
/// archive.
///
/// **Per archive rather than per batch, and that is the unit for both halves of it.** The rewrite
/// is per archive because that is what a repack is; the *question* is per archive because the
/// sentence names the archive and says whether Undo will be able to put it back — which depends on
/// that archive's size (``ArchiveUndoBudget``). One sheet covering two archives could not say
/// either thing truthfully.
///
/// **Still one sheet per archive, never none.** The remote half stays silent when its checks find
/// nothing, and this half deliberately does not: a repack rewrites a file the user did not name in
/// this gesture — they named it when they pressed ⏎, possibly an hour ago, possibly in an app that
/// autosaves — so silence here would rewrite an archive because a text editor flushed a buffer.
/// That reasoning is unchanged by batching; what changed is how many times it is put.
extension BrowserWindowController {
    /// Group by archive and run each group.
    ///
    /// Sequentially, because each group ends in a sheet and a rewrite: two archives being repacked
    /// at once would put two questions on screen and two `bsdtar` passes over the same disk.
    func runArchiveWriteBacks(_ batch: [PendingArchiveWriteBack]) async {
        for group in ArchiveWriteBackPlan.groups(of: batch) {
            await runArchiveWriteBack(group)
        }
    }

    /// Ask about one archive's members, then write them all back in one rewrite.
    private func runArchiveWriteBack(_ group: ArchiveWriteBackGroup) async {
        guard await confirmArchiveWriteBack(group) else { return }
        await writeArchiveMembersBack(group)
    }

    /// The one question for this archive.
    private func confirmArchiveWriteBack(_ group: ArchiveWriteBackGroup) async -> Bool {
        let alert = NSAlert()
        alert.messageText = Self.archiveWriteBackTitle(group)
        alert.informativeText = Self.archiveWriteBackBody(
            group,
            undoable: ArchiveUndoStorage.willBeUndoable(archiveAt: group.archivePath)
        )
        alert.addButton(withTitle: String(
            localized: "Save Back",
            comment: "Button that writes an edited member back into its archive."
        ))
        alert.addButton(withTitle: String(
            localized: "Keep Editing",
            comment: """
            Button that declines writing an edited member back, leaving the editor open so the \
            user can save again later.
            """
        ))
        // `NSAlert` binds Escape by matching the byte string "Cancel", which neither button is —
        // so the response, not the title, is what says which one ⎋ means (docs/NOTES.md).
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)
        // The watcher raised this, not the user, so a window that has gone away has nobody to ask —
        // and the answer to a question nobody was put is to write nothing back, which leaves every
        // copy watched and asks again on the next save.
        let response = await alert.sheetAnswer(over: window, whenUnasked: .cancel)
        return response == .alertFirstButtonReturn
    }

    /// Add every member of the group back in one rewrite.
    ///
    /// One `ArchiveWriter.add` over ``ArchiveMutation/Addition`` pairs, so members that came from
    /// *different folders* inside the archive still travel in a single pass — which is the whole
    /// difference between this and calling the old single-file spelling in a loop.
    private func writeArchiveMembersBack(_ group: ArchiveWriteBackGroup) async {
        // The passphrase prompt and its retry belong to a pane (it owns the sheet's parent window
        // and the funnel), so the write runs through whichever pane is focused. The *edits* did not
        // come from that pane and do not need to.
        let pane = focusedPanel
        let archivePath = group.archivePath
        let additions = group.additions
        let copies = group.items.map(\.edit.temporaryURL)
        await withCheckedContinuation { continuation in
            pane.withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
                try await BlockingWork.run {
                    Result {
                        try ArchiveWriter.add(
                            additions,
                            ofArchiveAt: archivePath,
                            passphrase: passphrase,
                            undo: ArchiveUndoStorage.request()
                        )
                    }
                }.get()
            } onSuccess: { [weak self] snapshot in
                self?.finishArchiveWriteBack(
                    group, snapshot: snapshot, copies: copies, pane: pane
                )
                continuation.resume()
            } onFailure: { [weak self] error in
                self?.presentArchiveWriteBackFailure(group, error: error, pane: pane)
                continuation.resume()
            }
        }
    }

    private func finishArchiveWriteBack(
        _ group: ArchiveWriteBackGroup,
        snapshot: ArchiveUndoSnapshot?,
        copies: [URL],
        pane: PanelViewController
    ) {
        // One record for the rewrite, not one per member: the container was repacked once, and the
        // only exact reversal is the container as it was.
        pane.journalArchiveRewrite(snapshot)
        // Stop watching the copies that have now been absorbed: the archive is a new file, and the
        // next open re-extracts. Leaving a watcher would offer the same edit again on the editor's
        // next autosave, against an archive that already has it.
        for copy in copies { editedFiles.stopWatching(copy) }
        // Any pane showing this archive is now listing a stale mount.
        refreshPanesShowingArchive(at: group.archivePath)
    }

    private func presentArchiveWriteBackFailure(
        _ group: ArchiveWriteBackGroup,
        error: any Error,
        pane: PanelViewController
    ) {
        pane.presentOperationFailure(
            message: Self.archiveWriteBackFailureTitle(group),
            detail: pane.describe(error)
        )
    }

    /// Drop the rewritten archive's stale mount and re-list any pane inside it.
    ///
    /// Both panes, by *content* rather than by role: the pane that opened the file may have
    /// navigated away, both may be inside the same archive, or neither may be — the same "ask which
    /// pane is showing this, don't assume" shape the pack outcome needed.
    ///
    /// Shared with ⌘Z, which swaps the container under whatever pane is standing in it
    /// (`+Undo`) — the same question, so the same answer rather than a second spelling of it.
    func refreshPanesShowingArchive(at archivePath: String) {
        for pane in [leftPanel, rightPanel] {
            guard pane.panel.path.backend.archivePath == archivePath else { continue }
            (pane.backend as? CompositeBackend)?.invalidateMountedArchive(at: archivePath)
            pane.refreshArchiveDirectory()
        }
    }

    // MARK: - What the user reads

    /// The title over an archive's write-back question.
    ///
    /// One member keeps the sentence it has always had, naming it: a batch must not make the
    /// ordinary single save read like a report about a set.
    static func archiveWriteBackTitle(_ group: ArchiveWriteBackGroup) -> String {
        let archiveName = (group.archivePath as NSString).lastPathComponent
        guard group.items.count > 1 else {
            let name = group.items.first?.edit.name ?? ""
            return String(
                localized: "Save “\(name)” back into “\(archiveName)”?",
                comment: """
                Title of the write-back prompt after an archive member was edited; the first %@ is \
                the file's name and the second the archive's.
                """
            )
        }
        let count = group.items.count
        return String(
            localized: "Save \(count) edited files back into “\(archiveName)”?",
            comment: """
            Title of the write-back prompt over several edited members of one archive; %1$lld is \
            how many files and %2$@ the archive's name.
            """
        )
    }

    /// What saving back will do, and whether it can be reversed.
    ///
    /// The undoability half is per **archive** rather than per file, which is why the question is
    /// too: the answer comes from that archive's size against the undo budget, so a sheet spanning
    /// two archives could not state it.
    static func archiveWriteBackBody(_ group: ArchiveWriteBackGroup, undoable: Bool) -> String {
        guard group.items.count > 1 else {
            return undoable
                ? String(
                    localized: """
                    You edited a copy that was extracted from the archive. Saving it back rewrites \
                    the archive; Undo puts it back.
                    """,
                    comment: """
                    Body of the write-back prompt when the rewrite will be undoable — Dirnex keeps \
                    a copy of the archive as it was.
                    """
                )
                : String(
                    localized: """
                    You edited a copy that was extracted from the archive. Saving it back rewrites \
                    the archive and can’t be undone.
                    """,
                    comment: """
                    Body of the write-back prompt when the archive is too large for Dirnex to keep \
                    a copy of, so the rewrite cannot be reversed.
                    """
                )
        }
        // "In one pass" is worth saying: the reader is being asked about forty files and is
        // entitled to know they cost one rewrite rather than forty.
        return undoable
            ? String(
                localized: """
                You edited copies that were extracted from the archive. Saving them back rewrites \
                the archive once, with all of them; Undo puts it back.
                """,
                comment: "Body of the batch write-back prompt when the rewrite will be undoable."
            )
            : String(
                localized: """
                You edited copies that were extracted from the archive. Saving them back rewrites \
                the archive once, with all of them, and can’t be undone.
                """,
                comment: """
                Body of the batch write-back prompt when the archive is too large for Dirnex to \
                keep a copy of.
                """
            )
    }

    /// The title when the rewrite failed. One member names it; a group names the archive, because
    /// the rewrite is what failed and it failed for all of them at once.
    static func archiveWriteBackFailureTitle(_ group: ArchiveWriteBackGroup) -> String {
        guard group.items.count > 1 else {
            let name = group.items.first?.edit.name ?? ""
            return String(
                localized: "Couldn’t save “\(name)” back",
                comment: "Alert title when writing an edited member back into its archive fails."
            )
        }
        let archiveName = (group.archivePath as NSString).lastPathComponent
        let count = group.items.count
        return String(
            localized: "Couldn’t save \(count) files back into “\(archiveName)”",
            comment: """
            Alert title when writing several edited members back into their archive fails; %1$lld \
            is how many files and %2$@ the archive's name.
            """
        )
    }
}
