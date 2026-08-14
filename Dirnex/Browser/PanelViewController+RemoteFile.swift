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
/// the passive path — the preview following the cursor — is bounded three ways it cannot exceed
/// (``prepareRemotePreview()``: a settle delay, a size cap, and abandonment the moment the cursor
/// leaves), while ``openRemotePreview(alreadyConfirmed:onReady:)``, ⏎ and F4 are keys somebody
/// pressed and may spend whatever the user agrees to. Same fork as Quick View's JavaScript switch
/// and Enter-vs-Unlock: "is this safe" and "should this happen unasked" are different questions.
///
/// **The passive path used to be no path at all**, and that shipped as a bug: turning Quick View on
/// fetched the row under the cursor and *nothing after it*, so entering a folder with the preview
/// still up drew the placeholder card for every file in it and the mode looked broken. The rule it
/// was protecting is real — a fetch per arrow key is a request per row the cursor passed over — but
/// the rule it was actually enforcing was "one file per time you switch the mode on", which is not a
/// rule anybody could have discovered. Reported by a user 2026-08-14.
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

    /// What a preview surface draws when the cursor is on a remote file whose bytes are not here —
    /// the file's name, its size, and what is (or is not) being done about it. `nil` when there is
    /// no such row, or when the bytes have arrived and the real preview can be shown.
    var remotePreviewPlaceholder: RemotePreviewPlaceholder? {
        guard let entry = remoteFileUnderCursor, cachedRemoteFileURL == nil else { return nil }
        let state: RemotePreviewPlaceholder.State = switch host?.remoteFileCache
            .automaticState(for: entry) {
        case .running?: .downloading
        case .failed?: .failed
        case nil: .awaitingRequest
        }
        return RemotePreviewPlaceholder(
            name: entry.name,
            size: entry.byteSize >= 0 ? FileFormatting.byteString(entry.byteSize) : nil,
            state: state
        )
    }

    // MARK: - Following the cursor

    /// Start the fetch the *preview* wants: the cursor has come to rest on a remote file, Quick View
    /// (or the ⌘Y panel) is up, and the bytes are not here. The remote twin of
    /// ``prepareArchivePreview(onReady:)``, and — like it — silent about failure, because it runs on
    /// cursor movement and an alert per arrow key is a question nobody asked.
    ///
    /// **Three bounds, and together they are what makes an unasked transfer defensible.** The cache
    /// waits out a settle delay, so a *sweep* through a folder requests nothing; `RemoteFetchPolicy`
    /// weighs the size against `.cursorPreview`, which **declines** rather than confirming, so a
    /// large or unmeasured object leaves the card up instead of raising a dialog on a keystroke; and
    /// leaving the row abandons the transfer outright, so the cost is what elapsed while the user was
    /// actually looking at it. Take any one away and this is the arrow-key spend the original
    /// no-passive-path rule was written against.
    ///
    /// Re-drives **both** preview surfaces on landing rather than taking an `onReady`: with Quick
    /// View and the ⌘Y panel both up there is one transfer and two things to repaint, and a callback
    /// belonging to whichever of them scheduled it would leave the other showing the placeholder for
    /// a file that is now on disk.
    func prepareRemotePreview() {
        guard let cache = host?.remoteFileCache else { return }
        guard let entry = remoteFileUnderCursor, cache.cachedURL(for: entry) == nil,
              RemoteFetchPolicy.decision(
                  forByteSize: entry.byteSize, purpose: .cursorPreview
              ) == .fetch
        else {
            cache.cancelAutomaticFetch()
            return
        }
        cache.scheduleAutomaticFetch(entry, using: backend) { [weak self] in
            guard let self else { return }
            host?.panelCursorDidChange(self)
            refreshQuickLookIfVisible()
        }
    }

    /// Stand the cursor-following fetch down because the surface that wanted it has gone away —
    /// Quick View closing, or the ⌘Y panel being dismissed.
    ///
    /// Guarded on the *other* surface, which follows the same cursor and is served by the same one
    /// transfer: with both up, closing one must not take the bytes away from the one still on
    /// screen. Nothing is stranded either way, since every preview delivery re-schedules the row and
    /// re-scheduling one already pending is a no-op.
    func endRemotePreview() {
        guard !isQuickLookFollowingThisPane else { return }
        host?.remoteFileCache.cancelAutomaticFetch()
    }

    // MARK: - The explicit gestures

    /// Fetch the file under the cursor so a preview can show it, then call `onReady` — the ⌘Y toggle,
    /// ⌃Q / ⌃⇧Q / ⌃⌥Q switching Quick View on, and the placeholder card's own Download button. Does
    /// nothing when the cursor is not on a remote file or its bytes are already here, so a caller can
    /// invoke it after every preview refresh.
    ///
    /// `alreadyConfirmed` says the gesture has itself put the file's size in front of the user and
    /// been told to go ahead, which is true of exactly one caller: the card draws the name and the
    /// size directly above its Download button, so `RemoteFetchPolicy`'s confirmation would be
    /// asking a question the click has already answered. It skips the *question* only — the deferred
    /// progress sheet, Stop, and the failure report all still happen.
    func openRemotePreview(
        alreadyConfirmed: Bool = false,
        onReady: @escaping @MainActor () -> Void
    ) {
        guard let entry = remoteFileUnderCursor, cachedRemoteFileURL == nil else { return }
        // A key supersedes the transfer nobody asked for rather than racing it for the same object —
        // and this is also the path that clears a failed attempt, so pressing the button after one
        // tries again instead of finding the row already spoken for.
        host?.remoteFileCache.cancelAutomaticFetch()
        fetchRemoteFile(entry, for: .preview, alreadyConfirmed: alreadyConfirmed) { [weak self] _ in
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
        alreadyConfirmed: Bool = false,
        then proceed: @escaping @MainActor (URL) -> Void,
        failureMessage: @escaping () -> String
    ) {
        guard let cache = host?.remoteFileCache else { return }
        let context = RemoteFetchPrompt.Context(
            backend: backend, cache: cache, window: view.window
        )
        let onFailure: (any Error) -> Void = { [weak self] error in
            self?.presentOperationFailure(
                message: failureMessage(),
                detail: self?.describe(error) ?? ""
            )
        }
        if alreadyConfirmed {
            RemoteFetchPrompt.fetchConfirmed(
                entry, in: context, then: proceed, onFailure: onFailure
            )
        } else {
            RemoteFetchPrompt.fetch(
                entry, for: purpose, in: context, then: proceed, onFailure: onFailure
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

/// What a preview surface draws in place of a remote file whose bytes are not here.
///
/// A card rather than a blank surface, because a blank one reads as "this file is empty" or as the
/// preview being broken — where the truth is one of three quite different things, which is why the
/// state is part of the value rather than left to the card to guess.
struct RemotePreviewPlaceholder: Equatable {
    /// Why there is no preview, which is the whole content of this card.
    ///
    /// Part of the value, and therefore part of the surface's loaded identity (see
    /// `QuickViewPreviewView.show`): every un-fetched remote file resolves to a `nil` URL, so
    /// without the state in here a card that starts downloading would go on saying it had not.
    enum State: Equatable {
        /// Nothing is happening and nothing will unless the user asks: the object is over
        /// `RemoteFetchPolicy`'s automatic threshold, or the server never said how large it is.
        case awaitingRequest
        /// A fetch is scheduled or running for this row.
        case downloading
        /// The automatic attempt failed. Silent by design — the card is the report, and its button
        /// is how the user gets the real error out of the explicit path.
        case failed
    }

    let name: String
    /// The formatted size, or `nil` when the server reported none.
    let size: String?
    let state: State
}
