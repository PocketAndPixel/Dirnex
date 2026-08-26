import DirnexCore

/// The staleness guards and sort context a list refresh runs under, read at the instant it was
/// requested. Named rather than a tuple so the five cannot be taken in the wrong order.
struct ListRefreshPlan {
    let token: Int
    let path: VFSPath
    let sort: FileSort
    let showHidden: Bool
    let sizes: [VFSPath: Int64]
}

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
        // A **merged** listing has no directory of its own, but it does have real ones underneath —
        // every trash, or iCloud's containers — and those change behind the pane's back (PLAN.md
        // §M8, §M9). One stream over all of them, re-gathering when any fires.
        if !mergedSources.isEmpty, backend.capabilities.contains(.watch) {
            watchMergedSources(for: path)
            return
        }
        // Any other virtual listing has nothing to watch: a `.search` path isn't a real location,
        // and its hits are a snapshot of a question that was asked once.
        guard path.backend == .local, backend.capabilities.contains(.watch) else {
            watcher = nil
            watchedSources = []
            return
        }
        watcher = DirectoryWatcher(path: path) { [weak self] in
            Task { @MainActor in self?.directoryDidChange(path) }
        }
        watchedSources = [path]
    }

    /// The directories the active tab's merged listing was gathered from, or empty for every other
    /// kind of tab (see `PanelTab.mergedSources`).
    var mergedSources: [VFSPath] {
        get { tabs[activeTabIndex].mergedSources }
        set { tabs[activeTabIndex].mergedSources = newValue }
    }

    /// Record what a merged listing was gathered from, and watch it.
    ///
    /// The stream is rebuilt only when it is not already covering exactly these directories — so a
    /// re-gather triggered *by* this stream does not tear it down and build another on every event,
    /// while anything that cost the pane its stream re-arms. `force` covers a listing arriving in a
    /// tab that was watching something else.
    ///
    /// The comparison is against `watchedSources` — what the live stream covers — rather than
    /// `mergedSources`, the active tab's record of its own listing. Comparing the tab's copy left a
    /// Trash tab permanently dead after the pane's *other* tab was visited: switching away pointed
    /// the pane's single watcher at that tab's directory, and switching back re-gathered with an
    /// unchanged source set, so the guard short-circuited and the stream was never rebuilt. Nothing
    /// trashed afterwards ever appeared (verified live — an FSEvents-armed log line that fired
    /// before the tab round-trip and never again after it).
    func watchMergedListing(sources: [VFSPath], force: Bool = false) {
        mergedSources = sources
        guard force || sources != watchedSources else { return }
        startWatching(panel.path)
    }

    /// Watch a merged listing's sources, keyed to the synthetic path on screen so a late event from
    /// a listing the pane has since left is ignored — the same guard the directory watcher keeps.
    ///
    /// The latency is deliberately longer than a directory's: emptying a Trash of 500 items is one
    /// burst of hundreds of events, and every one of them would otherwise re-list several
    /// directories to draw the same shrinking list.
    private func watchMergedSources(for path: VFSPath) {
        watcher = DirectoryWatcher(paths: mergedSources, latency: 0.4) { [weak self] in
            Task { @MainActor in
                guard let self, self.panel.path == path else { return }
                // Funnels to `reloadTrash` / `reloadICloudDrive`, which re-gather and re-render in
                // place, keeping the cursor by identity.
                self.refreshCurrentDirectory()
            }
        }
        watchedSources = mergedSources
    }

    /// A watched directory changed on disk. Re-list it and hand the fresh snapshot to
    /// `Panel`, which preserves the cursor and marks by identity. Guarded so a late
    /// event from a directory we've since navigated away from is ignored.
    private func directoryDidChange(_ watchedPath: VFSPath) {
        guard let plan = listRefreshPlan(for: watchedPath) else { return }
        Task { await performListRefresh(plan, wake: .filesystemEvent) }
    }

    /// What a list refresh was asked to do, as of the moment it was asked.
    ///
    /// Captured **synchronously by the caller**, which is load-bearing rather than tidy: the token
    /// and the path are the staleness guards, and the sort context has to describe the pane the
    /// event was about. Reading them one scheduling hop later answers for whatever the pane had
    /// become in the meantime — which is how this read before the refresh was split so the poll
    /// could await it.
    func listRefreshPlan(for watchedPath: VFSPath) -> ListRefreshPlan? {
        guard panel.path == watchedPath else { return nil }
        // Snapshot the sort context for the off-main sort (PLAN.md §M7 perf pass): a re-list of a
        // churning 100k directory must not re-sort on the main actor. `installSortedModel`
        // re-applies the live filter and any total that lands during the sort.
        return ListRefreshPlan(
            token: loadToken,
            path: watchedPath,
            sort: panel.model.sort,
            showHidden: panel.model.showHidden,
            sizes: panel.model.directorySizes
        )
    }

    /// The passive list refresh itself, `async` so its **caller** can know when it finished.
    ///
    /// That is the whole reason it is split from `directoryDidChange`: FSEvents is fire-and-forget,
    /// while the remote poll has to time its own refresh in order to space the next one
    /// (`RemoteRefreshPolicy` derives the interval from what the last one cost). Two wake sources,
    /// one definition of what a passive refresh *does* — the alternative is a second re-list that
    /// drifts from this one, which is this project's most repeated bug.
    func performListRefresh(_ plan: ListRefreshPlan, wake: RefreshWake) async {
        let watchedPath = plan.path
        let token = plan.token
        let sort = plan.sort
        let showHidden = plan.showHidden
        let sizes = plan.sizes
        guard let model = try? await DirectoryLoader.model(
            backend, at: watchedPath, sort: sort, showHidden: showHidden, directorySizes: sizes
        ) else { return }
        guard token == loadToken, panel.path == watchedPath else { return }
        if deferRefreshIfRenaming() { return }
        // **Only when the listing actually moved.** The stream is recursive, so the great
        // majority of events are about something far below this directory and change nothing the
        // pane draws: measured on `/Users/oleg` with nothing touched, ~5 events a second, every
        // one of them from `~/Library` (Chrome's cache, Spotlight's index, a sync client's
        // metrics) and the 27 rows identical throughout. Re-installing them anyway costs a full
        // `reloadData` several times a second, which the user *sees* — it tears down the
        // expansion tooltip on the row under the pointer, so a name too long for its column
        // blinks (docs/NOTES.md ▸ AppKit), and it is the same teardown `deferRefreshIfRenaming`
        // exists to keep away from an open rename field.
        //
        // This is the rule the other three consumers of this event already keep — `applyGitSnapshot`,
        // `applyTagSnapshot` and `applySyncSnapshot` each say "a no-op when nothing changed, so
        // the FSEvents-driven republish of an untouched directory costs no reload". The listing
        // was the one that did not, and it is the consumer that repaints every row. It is also
        // what makes a **poll** affordable at all: a server asked every fifteen seconds answers
        // "the same rows" nearly every time, and this is the line that turns that into no work.
        let listingChanged = model.listing != panel.model.listing
        if listingChanged {
            reconcileCursorFromTable()
            installSortedModel(model)
        }
        // Before the re-render, which re-seeds bars from the cache: the wake is the only proof
        // available that a cached total went stale, and seeding first would re-plant the number
        // we are about to disprove. `DirectoryWatcher` discards the event's paths and its stream
        // is recursive, so all an FSEvents ping proves is "something under here changed" — the
        // core's rule turns that into the right set of evictions (this line, root to leaf;
        // siblings survive). Unconditional for that wake, unlike the render: a change *below* a
        // folder is exactly what makes its cached total stale while leaving this directory's own
        // entries untouched.
        //
        // A **poll** cannot say that, which is the one thing the two wakes genuinely disagree
        // about (`RefreshWake.provesSubtreeChanged`). Nothing told it anything; the listing diff
        // is the whole of its evidence, and it says nothing about what is below these rows. So it
        // evicts only when the rows it can see actually moved. Inert today either way — a remote
        // path never enters `DirectorySizeProvider`, whose only writer is the local-only size-bar
        // scan — and gated regardless, because the day a budgeted remote walk banks a total there,
        // an ungated poll would drop a ten-minute answer every fifteen seconds and nothing would
        // say why.
        if wake.provesSubtreeChanged || listingChanged {
            invalidateDirectorySizes(under: watchedPath)
        }
        if listingChanged { renderRefresh() }
        // The three below still run on **every** event, unconditionally, and that is the point of
        // waking them separately: none of their states is derivable from the listing. `git add`
        // moves the gutter without touching a worktree file; a Finder tag is an xattr, which
        // changes no field of a `stat` this listing carries; a provider evicting a file changes
        // its badge. Each has its own no-op-when-unchanged guard, so an event that means nothing
        // to them costs no reload either.
        //
        // They are left unguarded by the wake because all four already refuse a non-local pane by
        // their own gates (`areTagsVisible`, `isSyncStatusVisible`, `areSizeBarsVisible`, and the
        // `.local` check in `updateGitStatus`) — and a poll only ever runs on a connected server.
        // A list of exceptions here would restate those gates in a second place, which is exactly
        // the drift the shared body exists to prevent.
        //
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
