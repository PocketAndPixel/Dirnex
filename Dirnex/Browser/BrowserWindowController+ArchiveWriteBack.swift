import AppKit
import DirnexCore

/// Putting an edited archive member back into the archive it came from (PLAN.md §M4
/// "edit-temp-watch-repack write-back").
///
/// The window owns this rather than a pane, for the reason the terminal drawer and Quick View are
/// window-scoped: an edit outlives whatever the panes are showing. Someone can open a file out of an
/// archive, navigate both panes elsewhere, close the tab, and save an hour later — and the answer
/// still has to be "put it back", not "the pane that started this is gone".
///
/// **It asks.** Repacking rewrites the whole archive and cannot be undone (the same wording F8 and
/// paste already use), so it is a mutation of a file the user did not name in this gesture — they
/// named it when they pressed ⏎, possibly a long time ago and possibly in an app that autosaves.
/// Silently rewriting an archive because a text editor flushed a buffer is the version of this
/// feature nobody asked for.
extension BrowserWindowController {
    /// A watched member has been saved — offer to write it back into `archivePath`, at
    /// `innerDirectory`.
    func offerArchiveWriteBack(
        _ edit: EditedFile,
        archivePath: String,
        innerDirectory: String
    ) {
        let archiveName = (archivePath as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Save “\(edit.name)” back into “\(archiveName)”?",
            comment: """
            Title of the write-back prompt after an archive member was edited; the first %@ is the \
            file's name and the second the archive's.
            """
        )
        alert.informativeText = String(
            localized: """
            You edited a copy that was extracted from the archive. Saving it back rewrites the \
            archive and can’t be undone.
            """,
            comment: "Body of the write-back prompt."
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

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.writeArchiveMemberBack(
                edit, archivePath: archivePath, innerDirectory: innerDirectory
            )
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    /// Add the edited copy back into the archive at the inner directory it came from, replacing the
    /// member of the same name — which is exactly `ArchiveWriter.add`, so write-back inherits the
    /// extract → edit → repack → atomic-swap rewrite and its encrypted route unchanged.
    private func writeArchiveMemberBack(
        _ edit: EditedFile,
        archivePath: String,
        innerDirectory: String
    ) {
        // The passphrase prompt and its retry belong to a pane (it owns the sheet's parent window
        // and the funnel), so the write runs through whichever pane is focused. The *edit* did not
        // come from that pane and does not need to: `edit` carries everything the write needs.
        let pane = focusedPanel
        let temporaryPath = edit.temporaryURL.path
        pane.withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
            try await Task.detached(priority: .userInitiated) {
                try ArchiveWriter.add(
                    localPaths: [temporaryPath],
                    toInnerDirectory: innerDirectory,
                    ofArchiveAt: archivePath,
                    passphrase: passphrase
                )
            }.value
        } onSuccess: { [weak self] in
            guard let self else { return }
            // Stop watching the copy that has now been absorbed: the archive is a new file, and the
            // next open re-extracts. Leaving the watcher would offer the same edit again on the
            // editor's next autosave, against an archive that already has it.
            editedFiles.stopWatching(edit.temporaryURL)
            // Any pane showing this archive is now listing a stale mount.
            refreshPanesShowingArchive(at: archivePath)
        } onFailure: { [weak self] error in
            self?.focusedPanel.presentOperationFailure(
                message: String(
                    localized: "Couldn’t save “\(edit.name)” back",
                    comment: "Alert title when writing an edited member back into its archive fails."
                ),
                detail: self?.focusedPanel.describe(error) ?? ""
            )
        }
    }

    /// Drop the rewritten archive's stale mount and re-list any pane inside it.
    ///
    /// Both panes, by *content* rather than by role: the pane that opened the file may have
    /// navigated away, both may be inside the same archive, or neither may be — the same "ask which
    /// pane is showing this, don't assume" shape the pack outcome needed.
    private func refreshPanesShowingArchive(at archivePath: String) {
        for pane in [leftPanel, rightPanel] {
            guard pane.panel.path.backend.archivePath == archivePath else { continue }
            (pane.backend as? CompositeBackend)?.invalidateMountedArchive(at: archivePath)
            pane.refreshArchiveDirectory()
        }
    }
}
