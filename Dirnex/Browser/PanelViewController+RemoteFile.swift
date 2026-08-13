import AppKit
import DirnexCore

/// Fetch-on-demand for a file that lives on a server — the pane's half of previewing, opening and
/// editing one in place (PLAN.md §M21 Slice 10).
///
/// Remote-generic on purpose: SFTP, FTP and S3 all answer `copyFile` in both directions and all
/// three carry `acceptsUploads`, so this is gated on `isRemoteConnection` rather than on S3. Writing
/// it against `isS3` would be one more instance of the finding this milestone keeps re-deriving —
/// one question, several spellings, and the compiler checks none of them.
///
/// **Two entry points, and the difference is who asked.** A local file or an extracted archive
/// member costs nothing to look at; a remote one costs a billed request and somebody's bandwidth. So
/// the passive path — the preview following the cursor — reads the cache and **cannot** fetch:
/// ``cachedRemoteFileURL`` has no transfer in it at all, which makes "an arrow key never spends a
/// request" structural rather than a rule somebody has to keep. ``openRemotePreview(onReady:)``,
/// ⏎ and F4 are keys somebody pressed and may. Same fork as Quick View's JavaScript switch and
/// Enter-vs-Unlock: "is this safe" and "should this happen unasked" are different questions.
extension PanelViewController {
    /// The remote file under this pane's cursor that a fetch could bring down: `nil` unless the pane
    /// is browsing a server and the cursor sits on a *file* (not the `..` row, not a directory, and
    /// so never a bucket row in an S3 account pane).
    var remoteFileUnderCursor: FileEntry? {
        guard !cursorOnParentRow, panel.path.backend.isRemoteConnection,
              let entry = panel.currentEntry, entry.kind == .file else { return nil }
        return entry
    }

    /// The downloaded copy of the file under the cursor, if one is already here and still matches
    /// the listing — otherwise `nil`, and the preview surfaces draw their placeholder instead.
    ///
    /// **Reads only.** This is called on every cursor movement, so anything that could start a
    /// transfer must not be in it; the freshness check compares against the `FileEntry` the pane is
    /// already displaying, which is why it costs nothing rather than a round trip.
    var cachedRemoteFileURL: URL? {
        guard let entry = remoteFileUnderCursor else { return nil }
        return host?.remoteFileCache.cachedURL(for: entry)
    }

    /// What a preview surface draws when the cursor is on a remote file nothing has fetched — the
    /// file's name and size, and how to ask for it. `nil` when there is no such row, or when the
    /// bytes are already here and the real preview can be shown.
    var remotePreviewPlaceholder: RemotePreviewPlaceholder? {
        guard let entry = remoteFileUnderCursor, cachedRemoteFileURL == nil else { return nil }
        return RemotePreviewPlaceholder(
            name: entry.name,
            size: entry.byteSize >= 0 ? FileFormatting.byteString(entry.byteSize) : nil
        )
    }

    // MARK: - The explicit gestures

    /// Fetch the file under the cursor so a preview can show it, then call `onReady` — the ⌘Y toggle,
    /// or ⌃Q / ⌃⇧Q / ⌃⌥Q switching Quick View on. Does nothing when the cursor is not on a remote
    /// file or its bytes are already here, so a caller can invoke it after every preview refresh.
    func openRemotePreview(onReady: @escaping @MainActor () -> Void) {
        guard let entry = remoteFileUnderCursor, cachedRemoteFileURL == nil else { return }
        fetchRemoteFile(entry, for: .preview) { [weak self] _ in
            // The cursor may have moved on during the transfer; showing what it has left behind
            // would put a stranger's file on screen under the current row's name.
            guard self?.remoteFileUnderCursor == entry else { return }
            onReady()
        } failureMessage: {
            String(
                localized: "Couldn’t preview this item",
                comment: """
                Alert title when a file on a server can't be downloaded for Quick Look or Quick View.
                """
            )
        }
    }

    /// ⏎ on a remote file — fetch it and hand it to whatever owns the type.
    ///
    /// The copy is registered for write-back exactly as F4's is, because an editor opened from ⏎
    /// saves the same way one opened from F4 does, and a save that quietly went nowhere is the
    /// failure the archive path already learned to avoid.
    func beginRemoteFileOpen(for entry: FileEntry) {
        fetchRemoteFile(entry, for: .open) { [weak self] url in
            self?.watchRemoteEdit(of: entry, at: url)
            NSWorkspace.shared.open(url)
        } failureMessage: {
            String(
                localized: "Couldn’t open this item",
                comment: "Alert title when a file on a server can't be downloaded to be opened."
            )
        }
    }

    /// F4 on a remote file — fetch it, open it in the chosen text editor, and offer to upload the
    /// save. Routed through `openInEditor` so it inherits F4's status line and its "no text editor
    /// found" reporting rather than growing a second copy of both.
    func beginRemoteFileEdit(for entry: FileEntry) {
        fetchRemoteFile(entry, for: .edit) { [weak self] url in
            self?.watchRemoteEdit(of: entry, at: url)
            self?.openInEditor(.local(url.path))
        } failureMessage: {
            String(
                localized: "Couldn’t open this item for editing",
                comment: "Alert title when a file on a server can't be downloaded to be edited."
            )
        }
    }

    /// Whether F4 can edit `entry` in place — a remote file on a backend that can receive the save
    /// back. Read by both the key and its menu validator, which are otherwise two copies of one
    /// predicate that drift (docs/NOTES.md ▸ AppKit: the size-bar lesson).
    func canEditRemoteFile(_ entry: FileEntry) -> Bool {
        entry.path.backend.isRemoteConnection && entry.path.backend.acceptsUploads
            && entry.kind == .file
    }

    // MARK: - Plumbing

    /// The one funnel every explicit gesture goes through: policy, the deferred sheet, the cache.
    private func fetchRemoteFile(
        _ entry: FileEntry,
        for purpose: RemoteFetchPurpose,
        then proceed: @escaping @MainActor (URL) -> Void,
        failureMessage: @escaping () -> String
    ) {
        guard let cache = host?.remoteFileCache else { return }
        RemoteFetchPrompt.fetch(
            entry,
            for: purpose,
            in: .init(backend: backend, cache: cache, window: view.window),
            then: proceed
        ) { [weak self] error in
            self?.presentOperationFailure(
                message: failureMessage(),
                detail: self?.describe(error) ?? ""
            )
        }
    }

    /// Watch the downloaded copy so a save is offered back up to the server it came from.
    ///
    /// Registering the same copy twice is a no-op, so opening a file with ⏎ and then editing it with
    /// F4 leaves one watcher on it rather than two questions on every save.
    private func watchRemoteEdit(of entry: FileEntry, at url: URL) {
        guard canEditRemoteFile(entry) else { return }
        host?.editedFiles.watch(EditedFile(
            destination: .remoteFile(entry.path),
            temporaryURL: url,
            name: entry.name
        ))
    }
}

/// What a preview surface draws in place of a remote file nobody has asked for yet.
///
/// A card rather than a blank surface, because a blank one reads as "this file is empty" or as the
/// preview being broken — where the truth is that Dirnex is deliberately *not* spending a request on
/// a row the cursor merely passed over.
struct RemotePreviewPlaceholder: Equatable {
    let name: String
    /// The formatted size, or `nil` when the server reported none.
    let size: String?
}
