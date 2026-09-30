import DirnexCore

/// Which directories a pane is **drawing**, for the window to ask after work that landed in one.
///
/// The window's own outcomes have to find the pane to re-list by *content* rather than by role: the
/// pane that started the work may have navigated away, both may be in the same place, or neither may
/// be. Every such site asked `pane.panel.path == directory`, which is the same sentence as this one
/// in a flat list and is not in a tree — a tree draws several directories at once, so a save-back
/// into a folder several levels down matched nothing at all.
///
/// Reported 2026-08-22: an S3 object edited from an account pane with its bucket expanded uploaded
/// perfectly and the row went on reading `Zero KB` with the old date, for the rest of the session.
/// Nothing logs, nothing fails, and the pane is showing a listing that was true a minute ago — the
/// same shape as the rename that did not refresh, one funnel further out.
extension PanelViewController {
    /// Every directory this pane holds rows from: its own, the real directories underneath a merged
    /// listing — whose own path is synthetic — and, in a tree, each row's *own* parent.
    ///
    /// **The rows, not the tree's listing keys**, and that is what makes it right for the case it was
    /// written for: `TreeProjection.listings` is keyed by the **row** that was expanded, which is not
    /// always the directory it holds. An expanded bucket in an S3 account pane files its children
    /// under `s3account:/<bucket>` while every row inside carries `s3://…`, so the keys name a path
    /// no object's parent will ever equal. A row's own path is where its bytes actually live.
    ///
    /// The pane's own path stays in regardless, because an empty directory has no row to derive it
    /// from and is exactly where a create lands.
    var displayedDirectories: Set<VFSPath> {
        var directories: Set<VFSPath> = [panel.path]
        directories.formUnion(mergedSources)
        for entry in panel.displayedEntries {
            if let parent = entry.path.parent { directories.insert(parent) }
        }
        return directories
    }

    /// Whether this pane is drawing the contents of `directory`, and so whether work that landed
    /// there has left a row on screen stale.
    func isShowing(_ directory: VFSPath) -> Bool {
        displayedDirectories.contains(directory)
    }
}
