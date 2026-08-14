import AppKit
import DirnexCore

/// Putting an edited remote file back on the server it came from (PLAN.md §M21 Slice 10).
///
/// The window owns this for the reason the archive write-back lives here: an edit outlives whatever
/// the panes are showing. Someone can open a file off a bucket, navigate both panes elsewhere, close
/// the tab, and save an hour later — and the answer still has to be "put it back".
///
/// **It re-`stat`s before it writes, and the dialog is worded from what that answered.** None of the
/// three remote protocols has a lock, and an upload is a whole-file write: S3's is a whole-object
/// `PUT`. So the ordinary hazard is not the transfer failing, it is the transfer *succeeding* and
/// silently erasing an edit somebody else made in the meantime, with nothing on screen at any point
/// to say so. One request answers it, and it is asked before the sheet appears rather than after the
/// user has agreed — so the sentence they are agreeing to is the true one.
///
/// **What "unchanged" is worth is said out loud**, because it differs by protocol and the difference
/// is not small: an FTP `LIST` stamp is year-less, zone-less and on the server's clock, so "same size
/// and date" over FTP misses most of a working day. `RemoteRevisionEvidence` names each blind spot
/// and this words them; a confidence percentage would be a number nobody can act on.
extension BrowserWindowController {
    /// A watched copy of a remote file has been saved — check the server, then offer to upload.
    func offerRemoteWriteBack(_ edit: EditedFile, to path: VFSPath) {
        let backend = focusedPanel.backend
        let recorded = remoteFileCache.revision(for: path)
        Task {
            let current = await BlockingWork.run { try? backend.stat(at: path) }
            presentRemoteWriteBackOffer(
                edit, to: path, recorded: recorded, current: current.map(RemoteFileRevision.init)
            )
        }
    }

    /// The one dialog, whose body says what the check found.
    private func presentRemoteWriteBackOffer(
        _ edit: EditedFile,
        to path: VFSPath,
        recorded: RemoteFileRevision?,
        current: RemoteFileRevision?
    ) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Upload “\(edit.name)” back to the server?",
            comment: """
            Title of the write-back prompt after a file downloaded from a server was edited; %@ is \
            the file's name.
            """
        )
        alert.informativeText = Self.writeBackBody(recorded: recorded, current: current)
        alert.addButton(withTitle: String(
            localized: "Upload",
            comment: "Button that uploads an edited file back to the server it came from."
        ))
        alert.addButton(withTitle: String(
            localized: "Keep Editing",
            comment: """
            Button that declines uploading an edited file, leaving the editor open so the user can \
            save again later.
            """
        ))
        // `NSAlert` binds Escape by matching the byte string "Cancel", which neither button is —
        // so the response, not the title, is what says which one ⎋ means (docs/NOTES.md).
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.uploadEditedFile(edit, to: path)
        }
        // The watcher raised this, not the user — see `beginSheetIfVisible`.
        alert.beginSheetIfVisible(over: window, completionHandler: handler)
    }

    /// What the re-`stat` found, in the user's terms.
    ///
    /// Four answers rather than two, and the split that matters is not "changed / unchanged" — it is
    /// that an *unchanged* answer is only as strong as the fields that could be compared. A
    /// difference is always real evidence of a write; an absence of difference is not, and over FTP
    /// it is barely evidence at all.
    ///
    /// `static` and pure so the wording is testable without a window.
    static func writeBackBody(
        recorded: RemoteFileRevision?,
        current: RemoteFileRevision?
    ) -> String {
        let overwrite = String(
            localized: "Uploading replaces the copy on the server and can’t be undone.",
            comment: "Sentence appended to every remote write-back prompt."
        )
        guard let current else {
            return String(
                localized: """
                Dirnex couldn’t reach the file on the server to check whether it has \
                changed. \(overwrite)
                """,
                comment: """
                Remote write-back body when the pre-upload check failed; %@ is the shared \
                “uploading replaces…” sentence.
                """
            )
        }
        guard let recorded else {
            return String(
                localized: """
                Dirnex has no record of what this file looked like when it was downloaded, so it \
                can’t tell whether anyone has changed it since. \(overwrite)
                """,
                comment: """
                Remote write-back body when nothing was recorded to compare against; %@ is the \
                shared “uploading replaces…” sentence.
                """
            )
        }
        guard !recorded.isSuperseded(by: current) else {
            return String(
                localized: """
                The file on the server has changed since you downloaded it — someone else has \
                edited it. \(overwrite)
                """,
                comment: """
                Remote write-back body when the server's copy was modified in the meantime; %@ is \
                the shared “uploading replaces…” sentence.
                """
            )
        }
        return unchangedBody(recorded.evidence(comparedWith: current), overwrite: overwrite)
    }

    /// The unchanged half, one sentence per blind spot.
    private static func unchangedBody(
        _ evidence: RemoteRevisionEvidence,
        overwrite: String
    ) -> String {
        switch evidence {
        case .entityTag:
            String(
                localized: """
                The file on the server is byte-for-byte the one you downloaded. \(overwrite)
                """,
                comment: """
                Remote write-back body when entity tags proved the server's copy is unchanged; %@ \
                is the shared “uploading replaces…” sentence.
                """
            )
        case .sizeAndTimestamp:
            String(
                localized: """
                The file on the server still has the size and modification date it had when you \
                downloaded it. \(overwrite)
                """,
                comment: """
                Remote write-back body when size and a trustworthy timestamp both matched; %@ is \
                the shared “uploading replaces…” sentence.
                """
            )
        case .sizeAndApproximateTimestamp:
            String(
                localized: """
                The file on the server still has the size and modification date it had when you \
                downloaded it — but FTP reports times without a year and on the server’s own clock, \
                so a recent change may not show up here. \(overwrite)
                """,
                comment: """
                Remote write-back body over FTP, whose LIST timestamps are too coarse to rely on; \
                %@ is the shared “uploading replaces…” sentence.
                """
            )
        case .sizeOnly:
            String(
                localized: """
                The server reports no modification date for this file, so only its size could be \
                checked — a change that kept the same length wouldn’t show up here. \(overwrite)
                """,
                comment: """
                Remote write-back body when the server gave no timestamp at all; %@ is the shared \
                “uploading replaces…” sentence.
                """
            )
        }
    }

    // MARK: - The upload

    /// Send the edited copy back up, then re-baseline what a *second* save will compare against.
    private func uploadEditedFile(_ edit: EditedFile, to path: VFSPath) {
        let backend = focusedPanel.backend
        let source = VFSPath.local(edit.temporaryURL.path)
        let url = edit.temporaryURL
        Task {
            let outcome = await BlockingWork.run { () -> Result<Void, any Error> in
                Result {
                    try backend.copyFile(
                        at: source, to: path, progress: { _ in }, isCancelled: { false }
                    )
                }
            }
            do {
                try outcome.get()
            } catch {
                focusedPanel.presentOperationFailure(
                    message: String(
                        localized: "Couldn’t upload “\(edit.name)”",
                        comment: """
                        Alert title when uploading an edited file back to its server fails; %@ is \
                        the file's name.
                        """
                    ),
                    detail: focusedPanel.describe(error)
                )
                return
            }
            // The watch deliberately stays: unlike a repack, an upload changes nothing on this Mac,
            // the editor still has this very file open, and a second save has to offer again
            // (`EditedFileRegistry.stopWatching`). What must move is the revision the *next* check
            // compares against — leaving the pre-upload one would have our own write read back as
            // "someone else has edited it", which is the one sentence that must never be wrong.
            await rebaseline(path, to: url, using: backend)
            refreshPanesShowing(path.parent)
        }
    }

    /// Re-read what the server now holds and record it as the copy's revision.
    ///
    /// A failed read drops the entry instead of keeping the stale one: with nothing recorded the
    /// next save says plainly that it cannot tell, which is true, where a stale revision would say
    /// something false with confidence.
    private func rebaseline(_ path: VFSPath, to url: URL, using backend: any VFSBackend) async {
        let uploaded = await BlockingWork.run { try? backend.stat(at: path) }
        guard let uploaded else {
            remoteFileCache.drop(path)
            return
        }
        remoteFileCache.rebaseline(path, to: RemoteFileRevision(uploaded), url: url)
    }

    /// Re-list any pane standing in `directory`, so the size and date it draws for the object are
    /// the ones just written.
    ///
    /// Both panes, by *content* rather than by role — the pane that opened the file may have
    /// navigated away, both may be in the same directory, or neither may be. The same "ask which
    /// pane is showing this, don't assume" shape the archive write-back and the pack outcome need.
    private func refreshPanesShowing(_ directory: VFSPath?) {
        guard let directory else { return }
        for pane in [leftPanel, rightPanel] where pane.panel.path == directory {
            pane.refreshCurrentDirectory()
        }
    }
}
