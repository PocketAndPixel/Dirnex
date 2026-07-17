import AppKit
import DirnexCore

/// Cloud sync status in a file pane: the badge at the right edge of each name (PLAN.md §M6
/// "iCloud/provider sync status"; the drawing is `SyncBadgeView`, the reading is
/// `CloudSyncStatusProvider`, and `DirnexCore`'s `CloudItemAttributes` owns what the attributes
/// mean). All this file does is keep the snapshot in step with the directory on screen.
///
/// **The badge lives inside the name cell, not in a column of its own** — where Finder puts it, and
/// what the plan's word "column" turned out to mean here, exactly as it did for tags. A column would
/// be blank for every row of every folder on a Mac without a cloud provider, which is most folders
/// on most Macs; the badge costs a synced row a few points of name width and everyone else nothing.
///
/// **Why there is no second watcher here, unlike Git.** A sync state is a property of the file
/// itself, so the pane's own directory watcher already fires when a provider materializes or evicts
/// one, and `directoryDidChange` re-derives status along with the listing — the same reasoning that
/// spared the tags side a watcher of its own.
extension PanelViewController {
    // MARK: - Per-tab state

    /// The sync status the active tab's rows are painted from — a copy of the provider's cache, held
    /// here so a row lookup is a plain read rather than a hit on the shared cache for every one of a
    /// hundred thousand rows. Per tab, so switching tabs restores the badges with everything else.
    var syncSnapshot: CloudSyncSnapshot? {
        get { tabs[activeTabIndex].syncSnapshot }
        set { tabs[activeTabIndex].syncSnapshot = newValue }
    }

    /// Whether badges belong on these rows: the user wants them, **and** these rows could be cloud
    /// items at all.
    ///
    /// The second half is not the preference being second-guessed — only local files are backed by a
    /// file provider, so inside an archive or on an SFTP volume there is nothing to ask about.
    /// Search results *do* qualify: the pane is virtual but every row in it is a real local file, so
    /// its badges are as real as any folder's.
    var isSyncStatusVisible: Bool {
        guard AppPreferences.shared.showSyncStatus else { return false }
        return panel.path.backend == .local || isSearchResults
    }

    // MARK: - Command (dispatched to the focused pane via the responder chain)

    /// View ▸ Show Sync Status. App-wide, like Show Tags — every pane and tab reflects it, via the
    /// preference's own notification rather than by reaching across to the other panes from here.
    @objc func toggleShowSyncStatus(_ sender: Any?) {
        AppPreferences.shared.toggleShowSyncStatus()
    }

    // MARK: - Keeping up to date

    func observeCloudSyncStatusChanges() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(cloudSyncStatusDidChange),
            name: CloudSyncStatusProvider.didChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(showSyncStatusPreferenceDidChange),
            name: AppPreferences.showSyncStatusDidChange,
            object: nil
        )
    }

    /// A directory this pane may be showing was re-scanned. Ignore every other one — with two panes
    /// and several tabs, most notifications are somebody else's.
    @objc private func cloudSyncStatusDidChange(_ notification: Notification) {
        guard let directory = notification.userInfo?[CloudSyncStatusProvider.directoryKey] as? VFSPath,
              directory == panel.path else { return }
        applySyncSnapshot(CloudSyncStatusProvider.shared.cachedSnapshot(for: directory))
    }

    /// The View-menu toggle flipped. Every pane picks the badges up or drops them live, without
    /// waiting for a navigation.
    @objc private func showSyncStatusPreferenceDidChange(_ notification: Notification) {
        updateSyncStatus()
    }

    /// Re-derive the active tab's sync status for the directory now on screen. Called on navigation,
    /// on a tab switch, on every live refresh, and when the preference flips.
    func updateSyncStatus() {
        guard isSyncStatusVisible else {
            clearSyncStatus()
            return
        }
        let directory = panel.path
        // The whole listing, not the visible rows: `requestRefresh` explains why a filtered pane
        // must not narrow what the shared cache holds.
        CloudSyncStatusProvider.shared.requestRefresh(
            for: directory,
            entries: panel.model.listing.entries.map(\.path)
        )
        // Whatever is already cached renders now; the scan republishes if it changed. Revisiting a
        // folder therefore paints its badges with the folder, not after it.
        applySyncSnapshot(CloudSyncStatusProvider.shared.cachedSnapshot(for: directory))
    }

    /// Adopt `snapshot` as what the active tab renders. A no-op when nothing changed, so the
    /// FSEvents-driven republish of an untouched directory costs no reload.
    private func applySyncSnapshot(_ snapshot: CloudSyncSnapshot?) {
        guard snapshot != syncSnapshot else { return }
        syncSnapshot = snapshot
        // A rename in progress owns the table; the end-editing handler replays what it skipped.
        if deferRefreshIfRenaming() { return }
        // `renderRefresh`, never a bare `reloadData`: a reload drops the table's selection, and the
        // cursor has to be re-applied from the model afterwards — including the `..` row. This is a
        // live background change like any other, so it re-anchors without scrolling: an arriving
        // badge must not yank the user's reading position.
        renderRefresh()
    }

    /// Drop the badges — leaving for an archive, or switching them off, must take them with it
    /// rather than leave the last folder's painted on.
    private func clearSyncStatus() {
        guard syncSnapshot != nil else { return }
        syncSnapshot = nil
        if deferRefreshIfRenaming() { return }
        renderRefresh()
    }

    // MARK: - Rendering

    /// The sync status of one row — `nil` when it has nothing to report, when the scan hasn't landed
    /// yet, or when the pane isn't showing status at all. That last case is what makes the
    /// preference work with no column to install: the cells simply render no badge, and the names
    /// take back the width.
    func syncStatus(for entry: FileEntry) -> CloudSyncStatus? {
        guard isSyncStatusVisible else { return nil }
        return syncSnapshot?.status(for: entry.path)
    }
}
