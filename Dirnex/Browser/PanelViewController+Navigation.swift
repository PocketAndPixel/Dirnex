import AppKit
import DirnexCore

/// Opening entries and walking the directory tree: the small navigation actions the
/// key model, double-click, and the `..` row funnel into. Kept out of the main
/// controller so it stays under SwiftLint's file/type-body limits (like `+Table`,
/// `+Chrome`, `+ParentRow`).
extension PanelViewController {
    /// Enter the directory under the cursor, browse into an archive file, or launch a plain
    /// file with its default app.
    func openCurrentEntry() {
        guard let entry = panel.currentEntry else { return }
        // Before the directory branch, because a `.sparsebundle` *is* a directory: entering one shows
        // `bands/`, `Info.plist` and `token` — the container's machinery — while the files the user
        // came for are on a mounted volume somewhere else entirely. An unlocked vault therefore read
        // as locked from the pane, and the only way in was the sidebar (user-reported 2026-08-10).
        if let vault = savedVault(for: entry) {
            host?.panelRequestsVaultOpen(vault, showingIn: self)
            return
        }
        // Also before the directory branch, and for the same shape of reason: a bucket row *is* a
        // directory, and the path it points at is one this backend deliberately refuses to list
        // (`S3AccountBackend` is depth 0 — everything below a bucket is reached by connecting to
        // it). Walking in is a backend crossing, so it is a connect (PLAN.md §M21 Slice 9).
        //
        // Asked of the **row**, not of the pane: a tree rooted on an account draws each expanded
        // bucket's contents beneath it on the `s3://` backend, and those are ordinary folders that
        // navigate (`VFSPath.isS3BucketRow`).
        if let bucket = s3BucketToEnter(for: entry) {
            enterS3Bucket(at: bucket)
            return
        }
        if let target = panel.openTarget(for: entry) {
            // A folder opened from a results tab must not replace the results in place — route it
            // elsewhere so the listing survives (PLAN.md §M4 search, §M8 Recents and Trash).
            //
            // The merged iCloud listing is the exception, and it is the same one that makes it
            // navigate in place to begin with (PLAN.md §M9): it is a *place*, not a set of hits, so
            // stepping into "Pages" should walk this pane into that folder the way stepping into any
            // folder does. Sending it to the other pane — which is right for a search you want to
            // keep — reads as the click going to the wrong window.
            if isResultsListing, !isICloudListing {
                openResultDirectory(target)
            } else {
                navigate(to: target)
            }
        } else if entry.path.backend == .local, ArchiveType.isBrowsable(entry.name) {
            // A local archive file — browse into its virtual folder tree instead of launching.
            navigate(to: archiveRoot(for: entry))
        } else if entry.path.backend.isArchive, ArchiveType.isBrowsable(entry.name) {
            // A nested archive — extract this member to disk and browse into it (PLAN.md §M4).
            beginNestedArchiveEntry(for: entry)
        } else if entry.path.backend == .local {
            // An evicted iCloud item has a real name and a real size and no bytes, so handing it
            // straight to `NSWorkspace` doesn't fail — it blocks whichever app opens it, silently,
            // for as long as the download takes (PLAN.md §M9). Fetch it first, visibly.
            CloudDownloadPrompt.materialize(entry, using: backend, over: view.window) { [weak self] in
                // A Google-native document on the Drive mount is a JSON pointer, not bytes
                // (PLAN.md §M10 Phase 1) — it opens in the browser, and only a file that turns out
                // not to be one falls through to its default app. The download-first wrapper is
                // the same one iCloud needs and comes first for the same reason: a stub can itself
                // be an unmaterialized File Provider item, and there is nothing to parse until it
                // is here.
                if !GoogleDocLauncher.open(entry) {
                    NSWorkspace.shared.open(entry.path.localURL)
                }
                // The badge that said "not downloaded" is now wrong. A real directory hears about
                // the materialization from its watcher; the merged iCloud listing has none, so it
                // re-gathers here or the arrow stays on a file that is fully local.
                if entry.isDataless, self?.isICloudListing == true {
                    self?.refreshCurrentDirectory(selecting: entry.path)
                }
            }
        } else if entry.path.backend.isArchive {
            // A plain file member — it has no local URL to hand `NSWorkspace`, so extract it to
            // temp and open *that* with its default app, the Total Commander gesture. Read-only,
            // because nothing writes an edit back into the archive (PLAN.md §M4).
            beginArchiveMemberOpen(for: entry)
        } else if entry.path.backend.isRemoteConnection {
            // A file on a server, for the same reason and by the same route: download it to temp and
            // open *that*, registering the copy so a save is offered back up (PLAN.md §M21 Slice
            // 10). Until this existed ⏎ fell off the end of this chain and did nothing whatsoever —
            // not even a message, which is the one outcome worse than a refusal.
            beginRemoteFileOpen(for: entry)
        }
    }

    /// The saved vault `entry` is the image of, if it is one.
    ///
    /// The store read is behind the suffix test rather than beside it: this runs on every Enter, and
    /// the overwhelming majority of them are on ordinary folders.
    private func savedVault(for entry: FileEntry) -> VaultLocation? {
        savedVault(for: entry, in: VaultStore.load())
    }

    /// The decision half, with the store handed in — so the rule is testable without a test writing
    /// a fake vault into the user's own `Dirnex.vaults`, which is the sidebar they are looking at.
    ///
    /// **Saved vaults only**, deliberately narrower than the Unlock command's `vaultImageUnderCursor`,
    /// which takes any image because the user named it. Enter is what you press to look inside things,
    /// so widening it to every `.dmg` would attach a stranger's disk image, ask for a passphrase, and
    /// file it in the sidebar's Vaults section — none of which anyone requested. An image Dirnex has
    /// no record of goes on browsing as the directory (or file) it is.
    func savedVault(for entry: FileEntry, in vaults: SavedVaults) -> VaultLocation? {
        guard entry.path.backend == .local, !isVirtualDirectory,
              DiskImageArguments.Kind.isImageName(entry.name) else { return nil }
        return vaults.vault(atPath: entry.path.path)
    }

    /// Open a directory picked from a results tab (search hits, Recents, or the Trash). The listing
    /// is what the user is browsing, so opening one of its folders never overwrites this tab: it
    /// lands in the **other** pane as a new tab (the "found it here, go look at it there" flow), or —
    /// when the window has no counterpart pane — as a new tab beside the results in this one.
    ///
    /// The `focusOpenedSearchDirectory` preference (default off) decides whether focus follows the
    /// opened folder or stays on the results so more hits can be opened in turn.
    private func openResultDirectory(_ target: VFSPath) {
        let focusFollows = AppPreferences.shared.focusOpenedSearchDirectory
        if let destination = host?.panelCounterpart(of: self) {
            // Always show the folder in the other pane; only move window focus there on request.
            destination.openInNewTab(target)
            if focusFollows {
                host?.panelRequestsFocusSwitch(self)
            }
        } else {
            // Single-pane: open beside the results here, switching to it only if focus should follow.
            openInNewTab(target, activate: focusFollows)
        }
    }

    /// Whether this pane can walk up from where it is — the **one** definition of that question.
    ///
    /// Three places ask it and each used to spell it out: the synthetic `..` row's
    /// ``parentRowCount``, ``goToParent()`` itself, and the Go menu's validator. All three read
    /// `backend == .local`, which is the shape docs/NOTES.md warns about — one rule, three
    /// spellings, and the compiler checks none of them. It cost every *remote* pane its way up:
    /// SFTP since M5, FTP since M13 and S3 since M21 had no `..` row, a dead Backspace and a grayed
    /// Go Up, and since both remote listing parsers strip the server's own `..` there was no row to
    /// fall back on either. Verified live 2026-08-13 standing inside an empty S3 folder — no rows at
    /// all, so the crumb was the only way out.
    ///
    /// A *virtual* pane is still excluded and that is the distinction the property exists to keep: a
    /// search snapshot's synthetic parent is not a browsable directory, while a connected account's
    /// is (`isRemoteConnection` — re-listable, and not on this disk).
    /// A bucket root is the one place where "up" is not a path at all: its path is `/`, so
    /// `parentPath` is `nil` and always will be, while the place above it — the account that holds
    /// it — is a different backend (`leavesBucketForItsAccount`). The row is offered even for a key
    /// that turns out not to be allowed to list buckets, because the alternative is asking the
    /// service on every listing to decide whether to draw a row; the walk itself probes once and
    /// says so where the user is standing (PLAN.md §M21 Slice 9).
    var canGoToParent: Bool {
        if isArchive { return true }
        if leavesBucketForItsAccount { return true }
        let backend = panel.path.backend
        guard backend == .local || backend.isRemoteConnection else { return false }
        return panel.parentPath != nil
    }

    /// Walk up one level, landing the cursor on the directory we came from. Inside an archive
    /// this walks the inner tree and, at the archive root, exits to the containing folder. A
    /// no-op on a virtual results pane — its synthetic parent isn't a browsable directory.
    func goToParent() {
        if isArchive {
            _ = goUpWithinArchive()
            return
        }
        // Before the `parentPath` walk, because a bucket root has no parent to walk to — the place
        // above it is the account, which is a connect (`PanelViewController+S3Account`).
        if leavesBucketForItsAccount {
            leaveBucketForItsAccount()
            return
        }
        guard canGoToParent else { return }
        let current = panel.path
        // Up out of iCloud Drive is the merged listing, not the container machinery that holds it:
        // the real parent of an app library's `Documents` is a one-child folder nobody asked to see,
        // and the real parent of a loose folder like "Car" is the CloudDocs container, which *is*
        // iCloud Drive as far as the listing is concerned (PLAN.md §M9). The cursor lands on the row
        // we came out of, as it does walking up anywhere.
        if ICloudDrive.walksUpToMerge(from: current) {
            showICloudDrive(selecting: current)
            return
        }
        guard let parent = panel.parentPath else { return }
        navigate(to: parent, focus: current)
    }

    /// Double-click: go up on the `..` row, otherwise open the clicked entry.
    @objc func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        if isParentRow(row) {
            goToParent()
            return
        }
        guard let index = entryIndex(forRow: row) else { return }
        panel.moveCursor(to: index)
        openCurrentEntry()
    }

    // MARK: - Loading a directory

    // Moved here from `PanelViewController` when the remote poll pushed that file past SwiftLint's
    // 500-line ceiling: this is the navigation the small actions above all funnel into, so the seam
    // is the concept's, not a line count's (docs/NOTES.md ▸ Lint ceilings and file splitting).

    /// Load `path` and install it in the active tab. When `focus` names a child that
    /// still exists (used when walking up), the cursor lands on it — the expected "go up,
    /// land on where I came from" behavior. A successful load records the visit in the tab's
    /// back/forward history (PLAN.md §M3) unless `recordHistory` is `false` — the flag
    /// back/forward/jump navigation passes so walking the trail doesn't append to it.
    /// Internal so `PanelViewController+Tabs` can load a freshly opened tab.
    ///
    /// `unasked` marks the **one** navigation nobody performed: the launch activation of a restored
    /// tab. It decides two things and only for that case — whether a restored server tab may open
    /// its connection (Settings ▸ Panels promises a floor of 0 means "never contact a server
    /// unasked"), and whether a failure is worth an alert (`presentLoadFailure`'s own rule: with
    /// nobody waiting for the answer, the pane is where it goes). Every gesture leaves it `false`,
    /// which is what gives a tab that came back disconnected a way out — clicking it, clicking a
    /// crumb, ⌘L, back/forward all connect.
    func navigate(
        to path: VFSPath,
        focus child: VFSPath? = nil,
        recordHistory: Bool = true,
        unasked: Bool = false
    ) {
        // A refusal here has already rendered the pane and invalidated whatever was in flight, so
        // there is nothing left for this navigation to do.
        guard canListAfterReconnecting(to: path, unasked: unasked) else { return }
        loadToken += 1
        // Whatever this pane was paying a server to measure, it has stopped looking at. A local
        // walk is untracked and deliberately survives — see `PanelViewController+Sizing`.
        cancelUnwatchedDirectorySizeWalks()
        let token = loadToken
        let tabIndex = activeTabIndex
        // Captured before the async load: was this tab showing a *non-re-listable* virtual pane
        // when we left? A `.search` results listing (and a browsed archive) can't be re-entered
        // from a history trail, so leaving one starts fresh. A connected remote *is* re-listable,
        // so it keeps a normal back/forward trail like a local directory.
        let wasVirtual = panel.path.backend != .local && !panel.path.backend.isRemoteConnection
        // Captured alongside it: was this tab showing a *results* listing? Its chip label and the
        // query behind "Save Search…" describe the results, not a place, so arriving at a real
        // directory has to drop them — otherwise clicking Home out of the Trash lands in the home
        // folder with the tab still chipped "Trash".
        let wasResults = isResultsListing
        // Captured before the load (`setListing` makes `panel.path` the destination): the departed
        // directory and its marks, so leaving a folder with marks records the loss against *that*
        // folder — undo restores them on return; a same-directory reload keeps marks, so it no-ops.
        let departed = panel.path
        let departedMarks = panel.selection
        Task {
            do {
                // Sort the fresh listing off the main thread (PLAN.md §M7 perf pass): a 100k
                // directory's ~350 ms `localizedStandardCompare` pass must not jank the pane.
                // Built with an empty filter, so entering a directory starts fresh — a quick-filter
                // from the folder we just left shouldn't silently hide the new folder's contents —
                // and with no computed sizes, since a directory we're arriving at has none yet.
                // Hidden files come from the app-wide toggle rather than the departed model: a
                // results listing forces them *on* (see `ResultsPresentation.showsHidden`), and
                // carrying that into a real directory would show dotfiles with the eye toggled off.
                let model = try await DirectoryLoader.model(
                    backend,
                    at: path,
                    sort: panel.model.sort,
                    showHidden: AppPreferences.shared.showHidden
                )
                guard token == loadToken else { return }
                panel.setModel(model)
                // Bring the pane into the tab's shape (PLAN.md §M15 Slice 4) before the render: a
                // fresh model is an all-collapsed tree, so this seeds `panel.tree` when the tab wants
                // one, and flattens back where a tree can't apply.
                applyViewMode()
                resetMouseSelectionAnchor()
                recordMarkChange(since: departedMarks, in: departed, label: .clearSelection)
                if let child, let index = panel.displayedIndex(ofID: child) {
                    panel.moveCursor(to: index)
                }
                // Land on a real entry; only an empty directory parks the cursor on `..`. Asked
                // through `canGoToParent` rather than through `parentPath`, so the flag cannot claim
                // the cursor is on a row the pane does not draw — which it did for an empty results
                // listing, whose synthetic path has a parent that is not somewhere to go.
                cursorOnParentRow = panel.isEmpty && canGoToParent
                // A restored tab's first listing: re-open the folders a restored tree had expanded,
                // listing each lazily…
                restorePendingTreeExpansion()
                // …then re-anchor its saved cursor and re-mark its saved selection, overriding the
                // defaults just set. Second, because a cursor or mark *inside* one of those folders
                // can only be anchored once that folder's rows exist — this pass takes whatever the
                // root already shows, and each expansion's landing re-runs it for the rest. A no-op
                // for every other navigation.
                applyPendingRestore(toTab: tabIndex)
                tabs[tabIndex].hasLoaded = true
                // Whatever the pane was explaining is now answered by the rows themselves.
                tabs[tabIndex].offlineReason = nil
                if wasResults { tabs[tabIndex].clearResultsIdentity() }
                if wasVirtual {
                    // Leaving a virtual results pane for a real directory starts a fresh trail —
                    // the synthetic `.search` path can't be re-listed, so it must never enter the
                    // back/forward history. Frecency still records the real destination.
                    tabs[tabIndex].history = NavigationHistory(initialPath: path)
                    FrecencyStore.shared.recordVisit(path)
                } else {
                    recordVisit(path, tab: tabIndex, recordHistory: recordHistory)
                }
                // The directory we just left has a scan queued against it that nobody will render.
                DirectorySizeProvider.shared.cancelScan(for: departed)
                reloadEverything()
                refreshTabBar()
                startPaneWatcher(path, force: true)
                updateGitStatus()
                updateTagStatus()
                updateSyncStatus()
                updateSizeVisualization()
                persistState()
                host?.panelDidNavigate(self)
            } catch {
                guard token == loadToken else { return }
                // An unasked load is a restore, and a restore has nobody waiting for its answer —
                // so it reports on the pane rather than over a window that may still be coming up.
                if unasked {
                    recordRestoreFailure(error, in: tabs[tabIndex])
                } else {
                    presentLoadFailure(error, path: path)
                }
            }
        }
    }
}
