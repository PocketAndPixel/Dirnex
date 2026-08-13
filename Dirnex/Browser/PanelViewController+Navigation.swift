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
        if panel.path.backend.isS3Account {
            enterS3Bucket(named: entry.name)
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
}
