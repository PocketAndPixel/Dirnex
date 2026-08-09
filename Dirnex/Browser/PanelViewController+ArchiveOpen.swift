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
/// **The extracted copy is made read-only, and that is the feature rather than a shortcut.** Nothing
/// here writes back into the archive, so an editor that saved would drop the user's work into a temp
/// directory that is purged at the next launch — silently, with the file still listed in the pane as
/// if the edit had landed. A locked file makes the save fail in front of them instead, and macOS's
/// own editors offer Duplicate at exactly that moment. Writing an edited member back is a later
/// slice; until it exists, failing loudly is the honest half of it.
extension PanelViewController {
    /// Extract the archive member under the cursor and open it with its default app.
    ///
    /// `entry` must be a non-directory member of the pane's archive that isn't itself a browsable
    /// archive — the caller (`openCurrentEntry`) has already routed those to `beginNestedArchiveEntry`.
    func beginArchiveMemberOpen(for entry: FileEntry) {
        guard let archivePath = panel.path.backend.archivePath, !entry.isDirectoryLike,
              let cache = host?.archivePreviewCache else { return }
        let member = ArchiveMember(archivePath: archivePath, innerPath: entry.path.path)

        withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
            try await cache.extractedURL(for: member, passphrase: passphrase)
        } onSuccess: { url in
            Self.lockExtractedMember(at: url)
            NSWorkspace.shared.open(url)
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

    /// Drop the extracted copy's write bits, so an edit fails in the editor rather than vanishing
    /// into a temp directory. Best-effort: a member that refuses the `chmod` still opens, since a
    /// file the user can read is the thing they asked for.
    private static func lockExtractedMember(at url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: url.path
        )
    }
}
