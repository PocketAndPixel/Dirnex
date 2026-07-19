import AppKit
import DirnexCore

/// Menu-item validation for a file pane: every checkmark, and every item that has to grey out where
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
            // panel still allows it (each target carries its real on-disk path).
            return !isArchive && !selectionTargets().isEmpty && host?.panelCounterpart(of: self) != nil
        case #selector(copy(_:)):
            // `copy:` only reaches the pane when the file table is first responder — a name/
            // path field editor intercepts ⌘C for text copy — so this validates the file case.
            // An archive entry has no on-disk URL to place on the pasteboard, and a remote SFTP
            // entry has no *local* one (F5 copies it out instead), so both are excluded.
            return !isArchive && !panel.path.backend.isSFTP && !selectionTargets().isEmpty
        case #selector(saveCurrentSearch(_:)):
            // Only meaningful on a results pane that still carries the query behind it.
            return canSaveCurrentSearch
        case #selector(showTagsMenu(_:)):
            // Only local files carry tags. Gated on the *targets*, not the pane, so tagging works
            // from a results tab (virtual pane, real local hits) — and, like ⌃D, ⌃T must reach a
            // field editor rather than being stolen to open a popup while a name is being typed.
            return canEditTags && !(view.window?.firstResponder is NSText)
        case #selector(undoLastOperation(_:)):
            return validateUndoItem(menuItem)
        case #selector(redoLastOperation(_:)):
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
            // virtual search-results pane.
            return isArchive || (panel.path.backend == .local && panel.parentPath != nil)
        case #selector(goBack(_:)):
            return tabs[activeTabIndex].history.canGoBack
        case #selector(goForward(_:)):
            return tabs[activeTabIndex].history.canGoForward
        case #selector(showHistory(_:)):
            // Like ⌃D, let ⌥↓ reach a field editor while a name/path field is being edited
            // instead of stealing it to open the history popup.
            return !(view.window?.firstResponder is NSText)
        case #selector(showHotlist(_:)):
            // While a name/path field is being edited, let ⌃D fall through to the field
            // editor's delete-forward instead of stealing it to open the hotlist.
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
    /// directory and so are all disabled on a virtual search-results pane (`isSearchResults`).
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
        case #selector(paste(_:)):
            // ⌘V pastes into a real writable folder, or *adds into* a writable browsed archive
            // (PLAN.md §M4 — a nested archive is read-only, so it's excluded).
            return (canWriteHere || isWritableArchive) && clipboardHasFiles()
        case #selector(pasteAndMoveFromClipboard(_:)):
            // ⌥⌘V has no standard selector, so it reaches the pane even mid text-edit — step it
            // aside for a field editor, else gate it like Paste.
            return canWriteHere && clipboardHasFiles() && !(view.window?.firstResponder is NSText)
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
            menuItem.title = ExternalDiffLauncher.preferredTool()
                .map { "Compare with \($0.displayName)…" } ?? "Compare By Contents…"
            // Diffs the two panes' cursor files — needs a real file under each cursor.
            return canCompareByContents
        default:
            return nil
        }
    }

    /// Validate the archive operations (Pack). Kept out of the main switch so it stays under
    /// SwiftLint's cyclomatic-complexity limit (a recurring gotcha). Returns `nil` for any other
    /// selector so the main switch handles it.
    private func validateArchiveItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
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
    /// `.read`, so `.write` is absent and the op greys out; a real disk (and a future writable
    /// SFTP mount) reports `.write`.
    private var canWriteHere: Bool {
        backend.capabilities(for: panel.path).contains(.write)
    }

    /// This pane can rename an item in place — the owning backend advertises `.rename`.
    private var canRenameHere: Bool {
        backend.capabilities(for: panel.path).contains(.rename)
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
            // Disabled where it cannot apply, so the greying explains the suppression that the
            // checkmark alone would leave looking like a bug.
            return panel.path.backend == .local && !isSearchResults
        case #selector(toggleGitAwareSizes(_:)):
            // The tab's flag again, not `areGitAwareSizesActive` — browsing out of a repository
            // suppresses the filtering, and unchecking the box would blame the user's setting.
            menuItem.state = isGitAwareSizesEnabled ? .on : .off
            // Greyed outside a repository, where there is nothing to exclude. `isInGitRepository`
            // rather than the snapshot: a repository whose first `git status` is still in flight is
            // one you are in, and the item must not flicker enabled a moment after the folder opens.
            return isInGitRepository
        case #selector(toggleQuickViewPanel(_:)):
            // "Quick View Panel" checkmark tracks the window-wide Quick View state.
            menuItem.state = (host?.isQuickViewEnabled ?? false) ? .on : .off
            return true
        default:
            return nil
        }
    }
}
