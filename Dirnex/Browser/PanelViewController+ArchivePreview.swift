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
    /// `nil` unless the pane is browsing an archive and the cursor sits on a *file* member
    /// (not the `..` row, not a directory). Its `innerPath` is what gets extracted.
    var previewableArchiveMember: ArchiveMember? {
        guard !cursorOnParentRow, let archivePath = panel.path.backend.archivePath,
              let entry = panel.currentEntry, !entry.isDirectoryLike else { return nil }
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
            guard (try? await cache.extractedURL(for: member, passphrase: passphrase)) != nil,
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
            try await cache.extractedURL(for: member, passphrase: passphrase)
        } onSuccess: { [weak self] _ in
            guard self?.previewableArchiveMember == member else { return }
            onReady()
        } onFailure: { [weak self] error in
            self?.presentOperationFailure(
                message: String(
                    localized: "Couldn’t preview this item",
                    comment: """
                    Alert title when an archive member can't be extracted for Quick Look or \
                    Quick View.
                    """
                ),
                detail: self?.describe(error) ?? ""
            )
        }
    }
}
