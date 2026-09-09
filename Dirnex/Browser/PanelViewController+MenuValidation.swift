import AppKit
import DirnexCore

/// Menu-item validation for a file pane: every checkmark, and every item that has to gray out where
/// it cannot apply (PLAN.md §M1 "menu items reflect what the focused pane can actually do").
///
/// Split out of `PanelViewController+FileOps`, which had grown past its length budget, along the
/// seam that file's own `MARK` already drew — the same split `PanelSizeTests` records making to
/// `PanelTests`. Nothing here mutates: it is the pane answering questions about itself.
extension PanelViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Boolean view toggles (checkmark items) and the directory-mutating ops are validated in
        // their own helpers so this switch stays under the cyclomatic-complexity limit.
        if let toggle = validateToggleItem(menuItem) { return toggle }
        if let mutating = validateMutatingItem(menuItem) { return mutating }
        if let archive = validateArchiveItem(menuItem) { return archive }
        if let navigation = validateNavigationItem(menuItem) { return navigation }
        if let handoff = validateHandoffItem(menuItem) { return handoff }
        if let automation = validateAutomationItem(menuItem) { return automation }
        switch menuItem.action {
        case #selector(copyToOtherPane(_:)):
            // Copy to the other pane works from a results panel (real paths) and from an archive,
            // where F5 becomes copy-*out* — extract the marked members to the other pane. Both
            // just need a counterpart to land in; the extraction path re-checks it's local.
            return !selectionTargets().isEmpty && host?.panelCounterpart(of: self) != nil
        case #selector(moveToOtherPane(_:)):
            // Move can't come out of a read-only archive (there's nothing to remove); a results
            // panel still allows it (each target carries its real on-disk path) — unless its rows
            // are themselves archive members, which is what a search inside an archive produces.
            let targets = selectionTargets()
            return !isArchive
                && extractionArchivePath(for: targets) == nil
                && !targets.isEmpty
                && host?.panelCounterpart(of: self) != nil
        case #selector(copy(_:)):
            // `copy:` only reaches the pane when the file table is first responder — a name/
            // path field editor intercepts ⌘C for text copy — so this validates the file case.
            // Since M23 the board carries a `PasteboardPayload` beside the file URL, so a row on a
            // connected remote copies like any other — and since Slice 5 an archive member does
            // too, its paste extracting through the funnel F5 copy-out uses.
            return canCopyToClipboard
        case #selector(saveCurrentSearch(_:)):
            // Only meaningful on a results pane that still carries the query behind it.
            return canSaveCurrentSearch
        case #selector(showTagsMenu(_:)):
            // Only local files carry tags. Gated on the *targets*, not the pane, so tagging works
            // from a results tab (virtual pane, real local hits) — and ⌃T must reach a field
            // editor (where it transposes) rather than being stolen to open a popup while a name
            // is being typed. The Favorites/Places popups need no such carve-out: they moved off
            // the ⌃-letter layer to ⌘F/⌘G, which the text system binds nothing on.
            return canEditTags && !(view.window?.firstResponder is NSText)
        case #selector(undo(_:)):
            return validateUndoItem(menuItem)
        case #selector(redo(_:)):
            return validateRedoItem(menuItem)
        default:
            return true
        }
    }

    /// Validate the Go menu's items. Returns `nil` for any other selector so the main switch
    /// handles it. Split out for the same reason as its siblings below: `validateMenuItem` has to
    /// stay under SwiftLint's cyclomatic-complexity limit (a recurring gotcha).
    private func validateNavigationItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(goToParentDirectory(_:)):
            // "Go Up" walks out of an archive too, but is meaningless at a backend root or on a
            // virtual search-results pane. Read from `canGoToParent` rather than restating it: this
            // menu item is the surface no headless test drives, so a validator carrying its own copy
            // of the rule is how a working command ends up grayed out (docs/NOTES.md — and it was,
            // for every remote pane, until 2026-08-13).
            return canGoToParent
        case #selector(findFiles(_:)):
            // Read from `canFindFiles` rather than restating its rule, for the reason `canGoToParent`
            // above exists: a validator carrying its own copy is how a working command ends up gray,
            // and this is the surface no headless test drives. An S3 *account* pane is the one place
            // it is false — its rows are buckets, so there is nothing to search and nothing local to
            // fall back to.
            return canFindFiles
        case #selector(goBack(_:)):
            return tabs[activeTabIndex].history.canGoBack
        case #selector(goForward(_:)):
            return tabs[activeTabIndex].history.canGoForward
        case #selector(showHistory(_:)):
            // Let ⌥↓ reach a field editor while a name/path field is being edited instead of
            // stealing it to open the history popup.
            return !(view.window?.firstResponder is NSText)
        case #selector(openInTerminal(_:)):
            // Needs a real directory on disk (never an archive, an SFTP server, or a results tab)
            // and a terminal to open it in — Terminal.app ships with macOS, so in practice this
            // only turns on the first half.
            return canOpenInTerminal
        default:
            return nil
        }
    }

    /// Validate the directory-mutating operations — the ones that need a real, writable
    /// directory and so are all disabled on a virtual search-results pane (`isResultsListing`).
    /// Returns `nil` for any other selector so the main switch handles it. Split out to keep
    /// `validateMenuItem` under SwiftLint's cyclomatic-complexity limit (a recurring gotcha).
    private func validateMutatingItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(newFolder(_:)):
            return canWriteHere
        case #selector(moveSelectionToTrash(_:)), #selector(deleteSelectionPermanently(_:)):
            // Inside a top-level archive, delete rewrites it to drop the members (no Trash, not
            // undoable) — enabled on a non-empty selection. Elsewhere the owning backend must be
            // able to delete at all: a search-results pane and a read-only nested archive report
            // `.read`, whose `deleteStrategy` is `.unsupported`, so both stay disabled.
            if isWritableArchive { return !selectionTargets().isEmpty }
            return backend.capabilities(for: panel.path).deleteStrategy != .unsupported
                && !selectionTargets().isEmpty
        case #selector(putBackSelection(_:)):
            // Only in a Trash listing, and only on something selected: outside one there is no
            // record of where anything came from, which is the whole operation.
            return isTrashListing && !selectionTargets().isEmpty
        case #selector(paste(_:)):
            // ⌘V pastes into any folder bytes can land in — this disk or a connected account since
            // M23 — or *adds into* a writable browsed archive (PLAN.md §M4 — a nested archive is
            // read-only, so it's excluded). `canReceiveFiles` rather than `canWriteHere`: an S3
            // account pane is writable (F7 creates a bucket) and is not somewhere a file can go.
            return (canReceiveFiles || isWritableArchive) && clipboardHasFiles()
        case #selector(pasteAndMoveFromClipboard(_:)):
            // ⌥⌘V has no standard selector, so it reaches the pane even mid text-edit — step it
            // aside for a field editor, else gate it like Paste.
            return canReceiveFiles && clipboardHasFiles()
                && !(view.window?.firstResponder is NSText)
        case #selector(renameSelection(_:)):
            // Rename is single-item on the cursor (not the marked set) and never `..`.
            return canRenameHere && !cursorOnParentRow && panel.currentEntry != nil
        case #selector(multiRenameSelection(_:)):
            // The batch tool operates on the marked set (else the cursor entry).
            return canRenameHere && !selectionTargets().isEmpty
        case #selector(synchronizeDirectories(_:)):
            // Compares the two panes' folders — needs two distinct real local directories.
            return canSynchronize
        case #selector(compareByContents(_:)):
            // Name the tool that would open, as the Synchronize sheet's row menu already does:
            // "Compare By Contents…" gives no hint what is about to launch, and with two tools
            // installed the answer depends on a setting. `validateMenuItem` is AppKit's only hook
            // for a title that tracks live state. The palette keeps the generic catalog title —
            // that one is what its fuzzy search matches against, so it must not move.
            // Both halves go through the lookup the *other* sites already use — the sheet's row
            // action for the named form, the registry for the generic one. Composing either as a
            // literal here draws English out of a translated catalog (docs/NOTES.md).
            menuItem.title = ExternalDiffLauncher.preferredTool().map { tool in
                String(
                    localized: "Compare with \(tool.displayName)…",
                    comment: "Menu item naming the diff tool that will open; %@ is the tool name."
                )
            } ?? LocalizedCatalog.command(for: "file.compareByContents")?.title ?? menuItem.title
            // Two real local files: marked in this pane (exactly two), else one under each cursor.
            return canCompareByContents
        case #selector(showAttributes(_:)):
            // Needs a real item on disk under the cursor: a mode, a flags word and an ACL are
            // things an inode has, which an archive member and an SFTP listing are not.
            return canShowAttributes
        case #selector(verifyChecksums(_:)):
            // Lights up only on a recognized checksum file under the cursor.
            return canVerifyChecksums
        case #selector(createChecksumFile(_:)):
            // Needs a real writable folder on disk and something selected. Remote panes stay gray:
            // neither `sftp` nor `curl` can hash server-side (PLAN.md §M14 Slice 2).
            return canCreateChecksumFile
        default:
            return nil
        }
    }

    /// Validate the archive operations (Pack, Archive Name Encoding). Kept out of the main switch
    /// so it stays under SwiftLint's cyclomatic-complexity limit (a recurring gotcha). Returns `nil`
    /// for any other selector so the main switch handles it.
    private func validateArchiveItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(chooseArchiveNameEncoding(_:)):
            // Read from `archiveAwaitingNameEncoding` rather than restating its rule, for the reason
            // `canGoToParent` above exists: a validator carrying its own copy of a predicate is how
            // a working command ends up grayed out, and the menu is the surface no headless test
            // drives. The action itself guards on the same property, so the two cannot disagree.
            return archiveAwaitingNameEncoding != nil
        case #selector(packSelection(_:)):
            // Pack a real local selection into a new archive in the other pane; the source must be
            // a real folder (not an archive or search-results view) and there must be a pane to
            // land the archive in. The pack flow re-checks the destination is local + writable.
            return canPackFromHere && !selectionTargets().isEmpty && host?.panelCounterpart(of: self) != nil
        default:
            return nil
        }
    }

    /// This pane can create/paste into its directory — driven off the *owning* backend's
    /// capabilities (PLAN.md §M5): a virtual pane (search results or a browsed archive) reports
    /// `.read`, so `.write` is absent and the op grays out; a real disk (and a future writable
    /// SFTP mount) reports `.write`.
    ///
    /// `creationDirectory` is the second half because the merged Trash is a virtual location that
    /// *does* carry `.write` — it holds real files that can be deleted — while having no directory to
    /// create or paste into. Without it, New Folder lit up in a Trash tab and the flow behind it
    /// bailed out silently at its own guard. The merged iCloud listing is the mirror image: also
    /// virtual, also writable, but it *does* have a directory underneath (CloudDocs), so it enables
    /// rather than grays — which is exactly why both ask the same question the flows themselves ask.
    ///
    /// It is the same property those flows resolve their destination from, spelled the same way so it
    /// cannot drift into a second predicate. Safe in a validator, which does not reconcile the cursor
    /// first: *which* directory follows the cursor in a tree, but *whether there is one* never does.
    private var canWriteHere: Bool {
        backend.capabilities(for: panel.path).contains(.write) && creationDirectory != nil
    }

    /// The row under the cursor can be renamed in place — the backend that owns the directory it
    /// lives in advertises `.rename`, and the name on screen is the name that would be edited.
    ///
    /// Internal, and asked by the **flows** as well as by this validator (F2's `beginRename`, ⇧F2's
    /// `beginMultiRename`), because two hand-written copies of one rule is how they drifted: the
    /// flows guarded on `backend.capabilities` — the composite's *backend-wide* set, which is always
    /// the local backend's — while this asked `capabilities(for:)`, the set of whichever backend owns
    /// the current path. The two then disagreed in both directions at once. On S3 the item was gray
    /// and the key worked, because S3 did not advertise `.rename` and the local backend does; in the
    /// merged iCloud listing the item was *enabled* and the key silently did nothing, because those
    /// rows are ordinary local files (so the capability is the local one) sitting in a listing with
    /// no directory of its own. One property answers both, so neither surface can be reached without
    /// the other (docs/NOTES.md ▸ AppKit — the size-bar and `canGoToParent` lessons).
    ///
    /// The second half is the **row**, not the pane. `FileEntry.nameMatchesPath` is false for
    /// exactly one kind of row in this app — the merged iCloud listing's app-library rows, which
    /// wear an app's name over its `Documents` folder — and renaming one would rename a folder the
    /// user is not looking at, under a name that is not the one they would be editing.
    ///
    /// It replaced `!isVirtualDirectory`, which was right about those rows and wrong about every row
    /// standing beside them: a loose file in the merged listing, a search hit, a row inside an
    /// expanded folder in either. All were refused for a property of the *container* rather than of
    /// themselves. Nothing else needed relaxing — an archive member and an S3 account's buckets are
    /// refused by the capability, and a trashed item by the `.rename` a trash withdraws, so each
    /// refusal now states its own reason instead of three of them sharing one flag.
    var canRenameHere: Bool {
        cursorRowCarriesItsOwnName && backend.capabilities(for: renameDirectory).contains(.rename)
    }

    /// Whether the row under the cursor shows its file's real name.
    ///
    /// `true` with no row under the cursor, which keeps this a question about a *location* for the
    /// callers that ask it that way: F2's validator adds `panel.currentEntry != nil` and ⇧F2's a
    /// non-empty selection, so an empty pane is refused there rather than here.
    private var cursorRowCarriesItsOwnName: Bool {
        guard !cursorOnParentRow, let entry = panel.currentEntry else { return true }
        return entry.nameMatchesPath
    }

    /// The directory whose backend decides whether the cursor's row can be renamed: the row's own,
    /// which is `performRename`'s `source.parent` — the directory the rename actually happens in.
    ///
    /// It used to be `panel.path`, and the two are the same answer in a plain directory listing,
    /// which is every listing this app had when the gate was written. Two shapes broke it:
    ///
    /// - **A tree** draws rows from several directories, and they can be on a different *backend*
    ///   than the pane (docs/NOTES.md ▸ the results-tab family). An S3 account pane is where that
    ///   reached a user: its own rows are buckets, which nothing can rename, so F2 three levels
    ///   inside an expanded bucket did nothing at all and File ▸ Rename… was gray beside it
    ///   (reported 2026-08-22). A cursor on a bucket row still answers with the account, and is
    ///   still — correctly — refused.
    /// - **A synthesized listing** has a container with no capabilities to speak of. A search hit
    ///   and a loose file in the merged iCloud listing are ordinary files in ordinary directories,
    ///   and asking `search:` or `icloud:` about them answered for the *presentation*.
    ///
    /// Deliberately **not** `Panel.cursorDirectory`, which stops at `panel.path` outside a tree —
    /// that property answers where a *create* lands, and there the pane's own directory is right
    /// (F7 in the merged iCloud listing creates in the CloudDocs container underneath, via
    /// `writeDirectory`, not beside whichever row the cursor happens to be on). Two questions that
    /// coincide in a plain listing and must not be collapsed.
    private var renameDirectory: VFSPath {
        // The `..` row stands for the pane's own parent rather than for any row, so a cursor parked
        // on it is pointing at nothing and the pane's own directory is the answer.
        guard !cursorOnParentRow, let directory = panel.currentEntry?.path.parent else {
            return panel.path
        }
        return directory
    }

    /// Boolean view toggles that carry a checkmark tracking their state and are always
    /// enabled (the standard macOS convention). Returns `nil` for any other selector so the
    /// main enable/disable switch handles it.
    private func validateToggleItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(toggleShowHidden(_:)):
            // "Show Hidden Files" checkmark tracks the app-wide state.
            menuItem.state = AppPreferences.shared.showHidden ? .on : .off
            return true
        case #selector(toggleShowTags(_:)):
            // "Show Tags" checkmark tracks the app-wide state — the preference itself, not
            // `isTagColumnVisible`: inside an archive the column is suppressed because there are no
            // tags to show there, and unchecking the box would blame the user's setting for it.
            menuItem.state = AppPreferences.shared.showTags ? .on : .off
            return true
        case #selector(toggleShowSyncStatus(_:)):
            // "Show Sync Status" checkmark tracks the app-wide state, not `isSyncStatusVisible` —
            // same reasoning as tags: an archive suppresses the badge because nothing in one can be
            // a cloud item, and unchecking the box would blame the user's setting for it.
            menuItem.state = AppPreferences.shared.showSyncStatus ? .on : .off
            return true
        case #selector(toggleFunctionBar(_:)):
            // "Show Function Key Bar" checkmark tracks the app-wide state.
            menuItem.state = AppPreferences.shared.showFunctionBar ? .on : .off
            return true
        case #selector(toggleSizeVisualization(_:)):
            // Tracks the tab's own flag rather than `areSizeBarsVisible`, for the reason above: on
            // an SFTP volume or in search results the bars are suppressed because there is nothing
            // sane to walk, and that is not the user having switched the mode off.
            menuItem.state = isSizeVisualizationEnabled ? .on : .off
            // Disabled where it cannot apply, so the graying explains the suppression that the
            // checkmark alone would leave looking like a bug. `canShowSizeBars` itself rather than a
            // hand-copy of it: this was a second spelling of `backend == .local`, and it was wrong
            // about an archive in exactly the same way its twin was.
            return canShowSizeBars
        case #selector(toggleTreeView(_:)):
            // Tracks the pane's *actual* shape (`panel.isTree`), not the tab's stored `viewMode`: a
            // tree preference is suppressed in an archive or on a remote volume, and the checkmark
            // must read as off there rather than blame the setting (the size-viz reasoning above).
            menuItem.state = panel.isTree ? .on : .off
            // Enabled only where a tree can apply — a real, local, on-disk directory.
            return canUseTreeMode
        case #selector(toggleGitAwareSizes(_:)):
            // The tab's flag again, not `areGitAwareSizesActive` — browsing out of a repository
            // suppresses the filtering, and unchecking the box would blame the user's setting.
            menuItem.state = isGitAwareSizesEnabled ? .on : .off
            // Grayed outside a repository, where there is nothing to exclude. `isInGitRepository`
            // rather than the snapshot: a repository whose first `git status` is still in flight is
            // one you are in, and the item must not flicker enabled a moment after the folder opens.
            return isInGitRepository
        default:
            return nil
        }
    }
}
