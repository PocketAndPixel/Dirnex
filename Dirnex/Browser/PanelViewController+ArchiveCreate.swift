import AppKit
import DirnexCore

/// F7 New Folder and ⇧F4's new file inside a browsed archive (taken 2026-11-05, closing two "no"
/// cells in docs/LOCATION-SUPPORT.md's archive column).
///
/// The dialogs are the local ones, unchanged: the same sheet, the same `/` refusal and the same
/// failure titles. Only the create differs. A member has no file of its own to `mkdir` or `open`, so
/// the container is rewritten the way F2 rewrites it (`ArchiveWriter.create`: extract, make the
/// member in the staged tree, repack, atomic swap).
///
/// **It does not confirm, for rename's reason.** A create destroys nothing: the staged `mkdir` and
/// `O_EXCL` refuse a name that is taken, so no member is ever replaced by an empty one. And it is
/// journaled, so ⌘Z puts the whole container back exactly as it does after F2, F8 or a paste.
///
/// **⇧F4 creates the empty member first and then opens it the way F4 opens any member** (taken by
/// the user 2026-11-05), so the row is under the cursor at once, as it is on disk, and the save goes
/// back through the usual write-back question. That costs a second rewrite on the first save, and
/// it is what makes ⇧F4 in an archive the same gesture as ⇧F4 in a folder.
extension PanelViewController {
    /// Rewrite the archive `member` belongs to with `creation` at `member`'s path, then re-list the
    /// pane with the cursor on the new row. `created` gets the new member read back from the
    /// rewritten archive: ⇧F4 hands it to the editor.
    ///
    /// The read-back goes through the backend rather than being assembled here, as the local ⇧F4's
    /// does and for the same reason: the edit route is decided from an *entry*, and the pane may
    /// have moved on by the time the rewrite lands, so the re-list cannot be relied on to hold it.
    func createArchiveMember(
        _ creation: ArchiveMutation.Creation,
        at member: VFSPath,
        then created: (@MainActor (FileEntry) -> Void)? = nil
    ) {
        guard let archivePath = member.backend.archivePath else { return }
        let name = member.lastComponent
        let innerDirectory = member.parent?.path ?? "/"
        let encoding = declaredNameEncoding(forArchiveAt: archivePath)
        // An encrypted archive is rewritten through libarchive and needs the passphrase — asked for
        // once per archive per session by the shared funnel, which also owns the retry on a typo.
        withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
            try await BlockingWork.run {
                Result {
                    try ArchiveWriter.create(
                        creation,
                        named: name,
                        inInnerDirectory: innerDirectory,
                        ofArchiveAt: archivePath,
                        passphrase: passphrase,
                        undo: ArchiveUndoStorage.request(),
                        nameEncoding: encoding
                    )
                }
            }.get()
        } onSuccess: { [weak self] snapshot in
            guard let self else { return }
            // The mounted TOC is now stale — drop it so the re-list re-reads the rewritten archive.
            (backend as? CompositeBackend)?.invalidateMountedArchive(at: archivePath)
            journalArchiveRewrite(snapshot)
            refreshArchiveDirectory { [weak self] in self?.moveCursor(onto: member) }
            focusTable()
            if let created { readBackCreatedMember(member, then: created) }
        } onFailure: { [weak self] error in
            guard let self else { return }
            // A legacy archive refuses before anything has been altered, and the answer is a code
            // page rather than an error message — so offer the chooser instead of reporting.
            guard !offerNameEncoding(after: error, forArchiveAt: archivePath) else { return }
            presentOperationFailure(
                message: creation == .folder
                    ? String(
                        localized: "Can’t create “\(name)”",
                        comment: "New Folder failure title; %@ is the folder name."
                    )
                    : String(
                        localized: "Can’t create “\(name)”",
                        comment: "Create-file failure title; %@ is the name."
                    ),
                detail: describe(error)
            )
        }
    }

    /// Put the cursor on the row a create has just made, when the re-list shows it.
    private func moveCursor(onto member: VFSPath) {
        guard let index = panel.displayedIndex(ofID: member) else { return }
        panel.moveCursor(to: index)
        cursorOnParentRow = false
        reloadEverything()
    }

    /// Stat the new member out of the rewritten archive and hand it on. A failure here is the
    /// *edit* that cannot happen, not the create, which has landed and is not retracted, so it is
    /// said with ⇧F4's own "Can't edit" title rather than left as a keystroke that opened nothing.
    private func readBackCreatedMember(
        _ member: VFSPath,
        then created: @escaping @MainActor (FileEntry) -> Void
    ) {
        let backend = backend
        Task {
            do {
                let entry = try await BlockingWork.run {
                    Result { try backend.stat(at: member) }
                }.get()
                created(entry)
            } catch {
                presentOperationFailure(
                    message: String(
                        localized: "Can’t edit “\(member.lastComponent)”",
                        comment: "Edit-file failure title; %@ is the name."
                    ),
                    detail: describe(error)
                )
            }
        }
    }
}
