import AppKit
import DirnexCore

/// Opening a file member of a browsed archive with its default app — Enter and double-click inside
/// an archive, the Total Commander gesture (PLAN.md §M4).
///
/// A member has no on-disk file, so this extracts it into the window's `ArchivePreviewCache` — the
/// same cache and the same key Quick Look and Quick View use, so previewing a member and then
/// opening it costs one extraction, not two — and hands the result to `NSWorkspace`. An encrypted
/// archive is asked for its passphrase first, once per archive per session, since Enter is an
/// explicit request for the member's bytes (PLAN.md §M19).
///
/// **The copy is writable, and saving it offers to put it back.** It shipped read-only for one day,
/// because an editor that saved would otherwise drop the user's work into a temp directory purged at
/// the next launch — silently, with the pane still listing the member as though the edit had landed.
/// A locked file at least failed in front of them. Write-back is the other half and the real answer:
/// the copy is registered with `EditedFileRegistry`, which watches it and, on a save, offers
/// the rewrite (`BrowserWindowController+ArchiveWriteBack`).
///
/// A **nested** archive is the exception and stays read-only: its own bytes are already an extracted
/// temp copy, so a write-back would land in a file that is thrown away rather than in the archive the
/// user is looking at. That is the same `isWritableArchive` line F8 and paste draw.
extension PanelViewController {
    /// Extract the archive member under the cursor and open it with its default app.
    ///
    /// `entry` must be a non-directory member of the pane's archive that isn't itself a browsable
    /// archive — the caller (`openCurrentEntry`) has already routed those to `beginNestedArchiveEntry`.
    func beginArchiveMemberOpen(for entry: FileEntry) {
        openArchiveMember(entry) { url in NSWorkspace.shared.open(url) }
    }

    /// The same, handing the extracted copy to the user's chosen text editor — F4 inside an archive.
    /// Routed through `openInEditor` so it inherits F4's status line and its "no editor found"
    /// reporting rather than growing a second copy of both.
    func beginArchiveMemberEdit(for entry: FileEntry) {
        openArchiveMember(entry) { [weak self] url in
            self?.openInEditor(.local(url.path))
        }
    }

    /// Extract the member (asking for a passphrase if the archive is encrypted), register it for
    /// write-back, and hand the on-disk copy to `launch`.
    private func openArchiveMember(_ entry: FileEntry, launch: @escaping @MainActor (URL) -> Void) {
        guard let archivePath = panel.path.backend.archivePath, !entry.isDirectoryLike,
              let cache = host?.archivePreviewCache else { return }
        let member = ArchiveMember(archivePath: archivePath, innerPath: entry.path.path)
        // The member's own directory inside the archive — where a write-back puts it back. Taken
        // from the entry rather than from the pane, since the pane can navigate away mid-edit.
        let innerDirectory = entry.path.parent?.path ?? "/"
        let writable = isWritableArchive

        withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
            try await cache.extractedURL(for: member, passphrase: passphrase)
        } onSuccess: { [weak self] url in
            if writable {
                self?.host?.editedFiles.watch(EditedFile(
                    destination: .archiveMember(
                        archivePath: archivePath, innerDirectory: innerDirectory
                    ),
                    temporaryURL: url,
                    name: entry.name
                ))
            } else {
                Self.lockExtractedMember(at: url)
            }
            launch(url)
        } onFailure: { [weak self] error in
            self?.presentOperationFailure(
                message: String(
                    localized: "Couldn’t open this item",
                    comment: "Alert title when a file inside a browsed archive can't be extracted."
                ),
                detail: self?.describe(error) ?? ""
            )
        }
    }

    /// Drop the extracted copy's write bits for the one case write-back cannot serve — a nested
    /// archive, whose own bytes are a temp copy. Best-effort: a member that refuses the `chmod`
    /// still opens, since a file the user can read is the thing they asked for.
    private static func lockExtractedMember(at url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: url.path
        )
    }
}
