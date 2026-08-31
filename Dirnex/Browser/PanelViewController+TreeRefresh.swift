import AppKit
import DirnexCore

/// The staleness guards a tree refresh runs under, read at the instant it was requested. Named
/// rather than a tuple so the three cannot be taken in the wrong order.
struct TreeRefreshPlan {
    let token: Int
    let root: VFSPath
    let directories: [VFSPath]
}

/// The tree's live refresh: the one FSEvents stream over every listed directory, and the re-list
/// that stream — or the remote poll — sets in motion.
///
/// Split out of `PanelViewController+Tree` along the seam its own
/// `// MARK: - The watcher over the expanded set` already drew, when the remote poll took that file
/// past SwiftLint's 500-line ceiling. The neighbouring file keeps the *projection* — what a tree is,
/// how a row expands and collapses, where its sizes live; this keeps *how it stays current*, which
/// is the list-mode `PanelViewController+Watch`'s twin one level up.
extension PanelViewController {
    // MARK: - The watcher over the expanded set

    /// Point the pane's single watcher at whatever the current mode needs: the whole listed-tree set
    /// in tree mode, or the one directory on screen in list mode. Called wherever a navigation or a
    /// tab switch (re-)establishes the watch.
    func startPaneWatcher(_ path: VFSPath, force: Bool = false) {
        if panel.isTree {
            startWatchingTree(force: force)
        } else {
            startWatching(path)
        }
        // The remote half of the same question. FSEvents covers a local pane exactly; a connected
        // server can notify nobody, so it is re-listed on a timer instead
        // (`PanelViewController+RemoteRefresh`). Both arm here, from the one funnel every navigation
        // and tab switch already goes through, so a pane can never end up watching one thing and
        // polling another.
        updateRemoteRefreshSchedule(force: force)
    }

    /// Watch every listed tree directory (root + each loaded expanded folder) through one FSEvents
    /// stream — one stream, not one per folder (PLAN.md §M15 Slice 4; the merged-listing lesson in
    /// NOTES.md). Rebuilt only when the *set* changes, or when `force`d — a mode switch keeps the
    /// same single path but must swap the callback from the list refresh to the tree one.
    func startWatchingTree(force: Bool = false) {
        guard panel.isTree else { return }
        // A tree rooted in an archive watches that archive's **file**, exactly as list mode does:
        // every directory such a tree lists is an `archive:` path, so `treeWatchSources` has
        // nothing to offer and the one thing that can change any of those rows is the container on
        // disk. Ahead of the set comparison because the set it would compare is empty — the archive
        // file is what `watchedSources` records here, so the stream is rebuilt on a change of
        // archive and not on every refresh.
        if let archiveFile = watchableArchiveFile(for: panel.path) {
            guard force || [archiveFile] != watchedSources else { return }
            watchArchiveFile(archiveFile, listing: panel.path)
            return
        }
        let sources = treeWatchSources
        guard force || sources != watchedSources else { return }
        // A tree whose listed directories are all remote or synthetic has nothing FSEvents can
        // watch. Tear the stream down rather than leave the previous location's running under a
        // listing it no longer describes.
        guard !sources.isEmpty else {
            watcher = nil
            watchedSources = []
            return
        }
        let root = panel.path
        watcher = DirectoryWatcher(paths: sources) { [weak self] in
            Task { @MainActor in
                guard let self, self.panel.isTree, self.panel.path == root else { return }
                // Not `refreshTree` directly: a merged root's rows come from a gather rather than
                // from a listing of the path on screen, so the funnel that knows which is which owns
                // the decision (it routes back here for a tree over a real directory).
                self.refreshCurrentDirectory()
            }
        }
        watchedSources = sources
    }

    /// The directories a tree watches: every listed one FSEvents can actually watch, plus the real
    /// directories behind a merged root — which is synthetic and cannot be watched itself, while what
    /// it was gathered from can (the same set list mode watches). Sorted so the equality check against
    /// `watchedSources` is stable (the core's set is unordered).
    ///
    /// Archive paths are filtered out here and watched separately, as the archive *file* they all
    /// come from (`startWatchingTree`): FSEvents cannot watch a path inside a `.zip`, and the file
    /// underneath answers for every row at once.
    ///
    /// The filter tests the path for **`.local`**, not its capabilities for `.watch`, and that is
    /// load-bearing rather than belt-and-braces: `CompositeBackend.capabilities(for:)` answers the
    /// *local* backend's full set for the merged iCloud container — deliberately, since its entries
    /// are ordinary local files — so a capability-only test would hand the synthetic `icloud:` path
    /// to FSEvents. Nothing would log; the stream would simply watch nothing.
    var treeWatchSources: [VFSPath] {
        let listed = panel.tree?.listedDirectories ?? [panel.path]
        let watchable = (listed + mergedSources).filter {
            $0.backend == .local && backend.capabilities(for: $0).contains(.watch)
        }
        return Array(Set(watchable)).sorted { $0.path < $1.path }
    }

    /// Re-list every directory the tree holds and update it in place, keeping the cursor and marks by
    /// identity. The FSEvents event names nothing (`DirectoryWatcher` discards its paths), so this
    /// refreshes the whole visible tree — which is a handful of listings, since trees are shallow.
    /// Internal so a tab switch can reuse it for a stale tree tab.
    ///
    /// `selecting` is the tree analogue of `refreshCurrentDirectory(selecting:)`: after an operation
    /// the app initiated (a rename, a New Folder, a delete), the target may live in a child directory
    /// the *root* re-list would never touch, so the whole tree is re-listed and the cursor is landed
    /// on the target by identity and scrolled to it — the way a list-mode refresh lands on a
    /// just-created entry. A passive FSEvents/tab-switch refresh passes `nil` and leaves the scroll
    /// position where it was.
    func refreshTree(selecting target: VFSPath? = nil) {
        guard let plan = treeRefreshPlan() else { return }
        Task { await performTreeRefresh(plan, selecting: target, wake: .filesystemEvent) }
    }

    /// What a tree refresh was asked to do, as of the moment it was asked.
    ///
    /// Captured **synchronously by the caller**, which is not incidental: these three are the
    /// staleness guards, and reading them one scheduling hop later would answer for whatever the
    /// pane had become rather than for the pane the event described. It is how this read before the
    /// refresh was split in two, and re-splitting it without the capture perturbed timing across
    /// the whole app suite.
    func treeRefreshPlan() -> TreeRefreshPlan? {
        guard let tree = panel.tree else { return nil }
        let root = panel.path
        return TreeRefreshPlan(
            token: loadToken,
            root: root,
            // A merged or results root is not a directory, so it cannot be re-listed by path: its
            // rows came from a gather, which owns re-producing them (`reloadICloudDrive` /
            // `reloadTrash`) and updates the tree's root level in place through
            // `installSortedModel`. A search snapshot has no re-gather at all and must keep the hits
            // it was given. Only the children are ours here.
            directories: tree.listedDirectories.filter { !(isResultsListing && $0 == root) }
        )
    }

    /// The tree refresh itself, `async` so its **caller** can know when it finished — the same
    /// split, for the same reason, as `performListRefresh`: the remote poll spaces its next round
    /// by what this one cost, and a tree over a server is where that matters most, since one
    /// refresh re-lists *every* expanded folder and so costs a request apiece.
    func performTreeRefresh(
        _ plan: TreeRefreshPlan,
        selecting target: VFSPath?,
        wake: RefreshWake
    ) async {
        let token = plan.token
        let root = plan.root
        let directories = plan.directories
        var listings: [(VFSPath, [FileEntry])] = []
        for directory in directories {
            // Through `treeChildEntries`, the same funnel the expansion used — a bucket row's
            // children are a *connection*, and listing `s3account:/<bucket>` throws `notFound`
            // into a `try?`, so a rename inside one left the old row on screen (2026-08-22).
            if let entries = await treeChildEntries(at: directory) {
                listings.append((directory, entries))
            }
        }
        guard token == loadToken, panel.isTree, panel.path == root else { return }
        if deferRefreshIfRenaming() { return }
        // **Which of them actually moved.** The stream is recursive over every listed directory,
        // so on a tree rooted anywhere near a busy subtree the great majority of events describe
        // something far below the deepest row: measured on a tree at `/Users/oleg` with nothing
        // touched, this ran ~5 times a second for half a minute and the 27 rows were identical
        // every time. Re-installing identical entries is not free — each pass ends in a
        // `renderRefresh`, whose `reloadData` the user *sees*, because it tears down the
        // expansion tooltip on the row under the pointer and a name too long for its column
        // blinks (docs/NOTES.md ▸ AppKit). The list-mode watcher keeps the same rule, and so do
        // the git, tag and sync consumers of this event.
        let changed = listings.filter { directory, entries in
            directory == root
                ? entries != panel.model.listing.entries
                : entries != panel.tree?.entries(in: directory)
        }
        reconcileCursorFromTable()
        for (directory, entries) in changed {
            if directory == root {
                // The root goes through the model too — it stays the settings-of-record the tree
                // is re-seeded from — while a child touches only the tree.
                panel.setListing(DirectoryListing(path: directory, entries: entries))
            } else {
                panel.setTreeChildListing(directory, entries: entries)
            }
        }
        // A real change landed somewhere under the tree; an FSEvents ping names nothing, so evict
        // every cached total on the root-to-leaf line (siblings survive) — the same honesty the flat
        // watcher keeps, so a revisit re-walks what grew rather than trusting the cache. The tree
        // keeps the totals it is already drawing (a stale total is an approximation, not a lie),
        // and `renderRefresh` re-queues anything now genuinely unsized.
        // Unconditional for that wake, unlike the render below: a change *below* a listed folder is
        // exactly what makes its cached total stale while leaving every row on screen untouched.
        //
        // A **poll** has no such proof and evicts only when the rows it can see moved — the one
        // point on which the two wakes genuinely differ, argued in full at `performListRefresh`.
        if wake.provesSubtreeChanged || !changed.isEmpty {
            invalidateDirectorySizes(under: root)
        }
        if let target, let index = panel.displayedIndex(ofID: target) {
            panel.moveCursor(to: index)
            cursorOnParentRow = false
            renderRefresh()
            syncCursorToTable(scroll: true)
        } else if !changed.isEmpty {
            renderRefresh()
        }
        startWatchingTree()
        updateGitStatus()
        updateTagStatus()
        updateSyncStatus()
    }
}
