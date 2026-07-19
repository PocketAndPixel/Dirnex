import AppKit
import DirnexCore

/// Extract-on-demand support for previewing an archive member (PLAN.md §M4 "Quick Look inside").
///
/// Quick Look (⌘Y) and Quick View (⌃Q) both need a real file on disk, which an archive member
/// doesn't have until it's extracted. When the cursor is on a member, this kicks off a single-
/// member extraction into the window's `ArchivePreviewCache` and, once it lands, re-drives the
/// caller's preview — which then finds the now-cached URL. The preview surfaces themselves
/// (`+QuickLook` / `+QuickView`) only ever read the cache synchronously, so they stay simple.
extension PanelViewController {
    /// The archive member under this pane's cursor that a preview can show by extracting it:
    /// `nil` unless the pane is browsing an archive and the cursor sits on a *file* member
    /// (not the `..` row, not a directory). Its `innerPath` is what `bsdtar` extracts.
    var previewableArchiveMember: ArchiveMember? {
        guard !cursorOnParentRow, let archivePath = panel.path.backend.archivePath,
              let entry = panel.currentEntry, !entry.isDirectoryLike else { return nil }
        return ArchiveMember(archivePath: archivePath, innerPath: entry.path.path)
    }

    /// Ensure the archive member under the cursor is on disk so a preview can show it, extracting
    /// it on demand into the window's cache and calling `onReady` once it lands. Does nothing and
    /// never calls back when the cursor isn't on a previewable member or it's already cached — so
    /// a caller can invoke it after every preview refresh without looping. A failed extraction (a
    /// damaged member) is swallowed: the member simply stays unpreviewable.
    func prepareArchivePreview(onReady: @escaping @MainActor () -> Void) {
        guard let member = previewableArchiveMember, let cache = host?.archivePreviewCache,
              cache.cachedURL(for: member) == nil else { return }
        Task {
            guard (try? await cache.extractedURL(for: member)) != nil,
                  previewableArchiveMember == member else { return }
            onReady()
        }
    }
}
