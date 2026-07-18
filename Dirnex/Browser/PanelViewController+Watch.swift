import AppKit
import DirnexCore

/// The pane's live refresh: the FSEvents watcher on the directory on screen, and everything one of
/// its pings sets in motion (PLAN.md §1 "the panel must reflect the filesystem as it changes").
///
/// Split out of `PanelViewController` along the seam its own `// MARK: - Live refresh (FSEvents)`
/// already drew, when size visualization made the class cross SwiftLint's type-body limit — the same
/// paid-down-not-suppressed move as pass 9's `PanelSizeTests`. The watcher itself stays a stored
/// property on the class, as stored properties must.
///
/// **One ping, four consumers.** A single event means the directory changed; what that *proves* is
/// different for each thing the pane draws, which is why they are woken separately rather than by one
/// blanket reload — see the ordering note in `directoryDidChange`.
extension PanelViewController {
    /// Watch `path` for changes, tearing down the previous watcher. The onChange closure
    /// runs on a background queue, so it hops to the main actor before touching the pane.
    /// Internal so a tab switch can re-establish the watcher for the newly active tab.
    func startWatching(_ path: VFSPath) {
        // A virtual results listing has no directory on disk to watch — its `.search` path isn't
        // a real location, and the results are a static snapshot.
        guard path.backend == .local, backend.capabilities.contains(.watch) else {
            watcher = nil
            return
        }
        watcher = DirectoryWatcher(path: path) { [weak self] in
            Task { @MainActor in self?.directoryDidChange(path) }
        }
    }

    /// A watched directory changed on disk. Re-list it and hand the fresh snapshot to
    /// `Panel`, which preserves the cursor and marks by identity. Guarded so a late
    /// event from a directory we've since navigated away from is ignored.
    private func directoryDidChange(_ watchedPath: VFSPath) {
        guard panel.path == watchedPath else { return }
        let token = loadToken
        // Snapshot the sort context for the off-main sort (PLAN.md §M7 perf pass): a re-list of a
        // churning 100k directory must not re-sort on the main actor. `installSortedModel` re-applies
        // the live filter and any total that lands during the sort.
        let sort = panel.model.sort
        let showHidden = panel.model.showHidden
        let sizes = panel.model.directorySizes
        Task {
            guard let model = try? await DirectoryLoader.model(
                backend, at: watchedPath, sort: sort, showHidden: showHidden, directorySizes: sizes
            ) else { return }
            guard token == loadToken, panel.path == watchedPath else { return }
            if deferRefreshIfRenaming() { return }
            reconcileCursorFromTable()
            installSortedModel(model)
            // Before the re-render, which re-seeds bars from the cache: this event is the only proof
            // available that a cached total went stale, and seeding first would re-plant the number
            // we are about to disprove. `DirectoryWatcher` discards the event's paths and its stream
            // is recursive, so all this proves is "something under here changed" — the core's rule
            // turns that into the right set of evictions (this line, root to leaf; siblings survive).
            invalidateDirectorySizes(under: watchedPath)
            renderRefresh()
            // Re-derives the repository too, so a `git init` (or a deleted `.git`) right here turns
            // the gutter on or off as it happens, rather than on the next navigation.
            updateGitStatus()
            // Tags need no watcher of their own: this event *is* the tag change (see +Tags).
            updateTagStatus()
            // Nor does sync status, for the same reason: a provider materializing or evicting a
            // file lands here as an event on the file itself (see +SyncStatus).
            updateSyncStatus()
            // Re-queues whatever the invalidation just dropped, so a folder that grew re-walks
            // instead of showing the total it had before.
            updateSizeVisualization()
        }
    }
}
