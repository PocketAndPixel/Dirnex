import AppKit
import DirnexCore

/// Extract-on-demand support for previewing an archive member (PLAN.md §M4 "Quick Look inside").
///
/// Quick Look (⌘Y) and Quick View (⌃Q) both need a real file on disk, which an archive member
/// doesn't have until it's extracted. When the cursor is on a member, this kicks off a single-
/// member extraction into the window's `ArchivePreviewCache` and, once it lands, re-drives the
/// caller's preview — which then finds the now-cached URL. The preview surfaces themselves
/// (`+QuickLook` / `+QuickView`) only ever read the cache synchronously, so they stay simple.
///
/// **Two entry points, and the difference is who asked.** An encrypted archive browses without a
/// passphrase — a zip's central directory is never encrypted — so the passphrase is wanted only when
/// bytes are. `openArchivePreview` is the key the user pressed and may raise the prompt;
/// `prepareArchivePreview` is the preview following the cursor and may not, since a sheet on an
/// arrow key is a question nobody asked. Once the archive has been unlocked once, both use the
/// remembered passphrase and the distinction stops mattering.
extension PanelViewController {
    /// The archive member under this pane's cursor that a preview can show by extracting it:
    /// `nil` unless the cursor sits on a *file* member of some archive (not the `..` row, not a
    /// directory). Its `innerPath` is what gets extracted.
    ///
    /// **Asked of the row, not of the pane** — the finding `extractionArchivePath(for:)` records for
    /// F5, one door over. A results tab's container is the synthetic `search:` path while its rows
    /// carry real `archive:` ones, so a pane-keyed question answers `nil` for a hit that is plainly
    /// an archive member, and ⌃Q / ⌘Y on it draw nothing at all. Which was the state M22 shipped
    /// Slice 2 in: the copy half was fixed live and the preview half, reached through a different
    /// property in a different file, was not.
    var previewableArchiveMember: ArchiveMember? {
        guard !cursorOnParentRow, let entry = panel.currentEntry, !entry.isDirectoryLike,
              let archivePath = entry.path.backend.archivePath else { return nil }
        return ArchiveMember(archivePath: archivePath, innerPath: entry.path.path)
    }

    /// Ensure the archive member under the cursor is on disk so a preview can show it, extracting
    /// it on demand into the window's cache and calling `onReady` once it lands. Does nothing and
    /// never calls back when the cursor isn't on a previewable member or it's already cached — so
    /// a caller can invoke it after every preview refresh without looping.
    ///
    /// Silent on failure by design: this runs on cursor movement, so a damaged member (or one in an
    /// archive nobody has unlocked yet) simply stays unpreviewable rather than raising an alert the
    /// user would then have to dismiss on every arrow key.
    func prepareArchivePreview(onReady: @escaping @MainActor () -> Void) {
        guard let member = previewableArchiveMember, let cache = host?.archivePreviewCache,
              cache.cachedURL(for: member) == nil else { return }
        let passphrase = rememberedPassphrase(forArchiveAt: member.archivePath)
        Task {
            guard (try? await cache.extractedURL(
                for: member,
                passphrase: passphrase,
                nameEncoding: self.declaredNameEncoding(forArchiveAt: member.archivePath)
            )) != nil,
                previewableArchiveMember == member else { return }
            onReady()
        }
    }

    /// The same, for the gesture that *opened* the preview — the ⌘Y toggle, or ⌃Q / ⌃⇧Q / ⌃⌥Q
    /// switching Quick View on. An encrypted archive is asked for its passphrase here (once per
    /// archive per session), and a member that still can't be read says so rather than leaving the
    /// key looking broken, which is the whole difference from the passive path above.
    func openArchivePreview(onReady: @escaping @MainActor () -> Void) {
        guard let member = previewableArchiveMember, let cache = host?.archivePreviewCache,
              cache.cachedURL(for: member) == nil else { return }
        withArchivePassphrase(forArchiveAt: member.archivePath) { passphrase in
            try await cache.extractedURL(
                for: member,
                passphrase: passphrase,
                nameEncoding: self.declaredNameEncoding(forArchiveAt: member.archivePath)
            )
        } onSuccess: { [weak self] _ in
            guard self?.previewableArchiveMember == member else { return }
            onReady()
        } onFailure: { [weak self] error in
            guard let self else { return }
            guard !offerNameEncoding(after: error, forArchiveAt: member.archivePath) else { return }
            presentOperationFailure(
                message: String(
                    localized: "Couldn’t preview this item",
                    comment: """
                    Alert title when an archive member can't be extracted for Quick Look or \
                    Quick View.
                    """
                ),
                detail: describe(error)
            )
        }
    }
}
