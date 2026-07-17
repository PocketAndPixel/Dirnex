import AppKit
import DirnexCore

/// Finder tags in a file pane: the dots at the right edge of each name (PLAN.md §M6 "Finder tags:
/// column, edit from panel…"; the editing half is `PanelViewController+TagEditing`, the drawing is
/// `TagDotsView`). The pane owns *when* to look, `FinderTagProvider` owns the looking, and
/// `DirnexCore`'s `FinderTag` owns what the bytes mean — so all this file does is keep the snapshot
/// in step with the directory on screen.
///
/// **The dots live inside the name cell, not in a column of their own** — where Finder puts them,
/// and what the plan's word "column" turned out to mean in practice. The Git gutter needs its own
/// column because it is *text*, competing for the name field's colour with the mark's red and the
/// hidden-file dim, and F2 swaps that field for an editor. Dots are their own view, so none of that
/// applies: they cost a tagged row a few points of name width and an untagged row nothing at all,
/// which is a better bargain than a column that is blank for most people in most folders.
///
/// **Why there is no second watcher here, unlike Git.** The Git side had to watch the *repository
/// root*, because `git add` in a terminal changes what a pane's rows should say while touching
/// nothing underneath the folder on screen — the index and `HEAD` live elsewhere. A tag has no
/// elsewhere: it is an extended attribute **on the file itself**, so the pane's own directory
/// watcher already fires for it, and `directoryDidChange` re-derives tags along with the listing.
extension PanelViewController {
    // MARK: - Per-tab state

    /// The tags the active tab's rows are painted from — a copy of the provider's cache, held here
    /// so a row lookup is a plain read rather than a hit on the shared cache for every one of a
    /// hundred thousand rows. Per tab, so switching tabs restores the dots with everything else.
    var tagSnapshot: FinderTagSnapshot? {
        get { tabs[activeTabIndex].tagSnapshot }
        set { tabs[activeTabIndex].tagSnapshot = newValue }
    }

    /// Whether dots belong on these rows: the user wants them, **and** these rows could carry tags
    /// at all.
    ///
    /// The second half is not the preference being second-guessed — it is that only local files have
    /// extended attributes, so inside an archive or on an SFTP volume there is nothing to scan for.
    /// Search results *do* qualify: the pane is virtual but every row in it is a real local file, so
    /// its dots are as real as any folder's.
    var areTagsVisible: Bool {
        guard AppPreferences.shared.showTags else { return false }
        return panel.path.backend == .local || isSearchResults
    }

    // MARK: - Command (dispatched to the focused pane via the responder chain)

    /// View ▸ Show Tags. App-wide, like ⇧⌘. — every pane and tab reflects it, via the preference's
    /// own notification rather than by reaching across to the other panes from here.
    @objc func toggleShowTags(_ sender: Any?) {
        AppPreferences.shared.toggleShowTags()
    }

    // MARK: - Keeping up to date

    func observeFinderTagChanges() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(finderTagsDidChange),
            name: FinderTagProvider.didChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(showTagsPreferenceDidChange),
            name: AppPreferences.showTagsDidChange,
            object: nil
        )
    }

    /// A directory this pane may be showing was re-scanned. Ignore every other one — with two panes
    /// and several tabs, most notifications are somebody else's.
    @objc private func finderTagsDidChange(_ notification: Notification) {
        guard let directory = notification.userInfo?[FinderTagProvider.directoryKey] as? VFSPath,
              directory == panel.path else { return }
        applyTagSnapshot(FinderTagProvider.shared.cachedSnapshot(for: directory))
    }

    /// The View-menu toggle flipped. Every pane picks the dots up or drops them live, without
    /// waiting for a navigation — a toggle you have to walk somewhere to see the effect of reads as
    /// broken.
    @objc private func showTagsPreferenceDidChange(_ notification: Notification) {
        updateTagStatus()
    }

    /// Re-derive the active tab's tags for the directory now on screen. Called on navigation, on a
    /// tab switch, on every live refresh, and when the preference flips.
    func updateTagStatus() {
        guard areTagsVisible else {
            clearTagStatus()
            return
        }
        let directory = panel.path
        // The whole listing, not the visible rows: `requestRefresh` explains why a filtered pane
        // must not narrow what the shared cache holds.
        FinderTagProvider.shared.requestRefresh(
            for: directory,
            entries: panel.model.listing.entries.map(\.path)
        )
        // Whatever is already cached renders now; the scan republishes if it changed. Revisiting a
        // folder therefore paints its dots with the folder, not after it.
        applyTagSnapshot(FinderTagProvider.shared.cachedSnapshot(for: directory))
    }

    /// Ask for a re-scan of the directory on screen — what the tag editor calls after writing, so
    /// the dots follow the edit without waiting for FSEvents to come back around.
    func refreshTagsAfterEdit() {
        guard areTagsVisible else { return }
        FinderTagProvider.shared.requestRefresh(
            for: panel.path,
            entries: panel.model.listing.entries.map(\.path)
        )
    }

    /// Adopt `snapshot` as what the active tab renders. A no-op when nothing changed, so the
    /// FSEvents-driven republish of an untouched directory (someone saved a file in it) costs no
    /// reload — see `FinderTagSnapshot.==`, which had to be hand-rolled to make that check honest.
    private func applyTagSnapshot(_ snapshot: FinderTagSnapshot?) {
        guard snapshot != tagSnapshot else { return }
        tagSnapshot = snapshot
        // A rename in progress owns the table; the end-editing handler replays what it skipped.
        if deferRefreshIfRenaming() { return }
        // `renderRefresh`, never a bare `reloadData`: a reload drops the table's selection, and the
        // cursor has to be re-applied from the model afterwards — including the `..` row, which the
        // model doesn't know about and only `cursorOnParentRow` remembers. This is a live
        // background change like any other, so it re-anchors without scrolling: arriving dots must
        // not yank the user's reading position.
        renderRefresh()
    }

    /// Drop the tags — leaving for an archive, or switching them off, must take the dots with it
    /// rather than leave the last folder's painted on.
    private func clearTagStatus() {
        guard tagSnapshot != nil else { return }
        tagSnapshot = nil
        if deferRefreshIfRenaming() { return }
        renderRefresh()
    }

    // MARK: - Rendering

    /// The tags on one row, **as they should be drawn** — `[]` when it has none, when the scan hasn't
    /// landed yet, or when the pane isn't showing tags at all. That last case is what makes the
    /// preference work with no column to install: the cells simply render no dots, and the names take
    /// back the width.
    ///
    /// The colours come from the tag's *name*, not from the file: `FinderTagProvider.resolve` — and
    /// the core's `FinderTagIndex` behind it — explains why the byte on disk is unusable for drawing
    /// anywhere inside iCloud Drive, where every tagged file stores grey and Finder paints it red
    /// regardless. Resolving here, at the point of drawing, rather than folding it into the snapshot,
    /// keeps `FinderTagSnapshot` meaning *what the files say* — which is what `FinderTagSnapshot.==`
    /// compares to decide a repaint, and what a later scan can legitimately find changed.
    func tags(for entry: FileEntry) -> [FinderTag] {
        guard areTagsVisible, let stored = tagSnapshot?.tags(for: entry.path), !stored.isEmpty else {
            return []
        }
        return FinderTagProvider.shared.resolve(stored)
    }
}
