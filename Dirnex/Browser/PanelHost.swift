import AppKit
import DirnexCore

/// The pane's owner (the window controller) — receives focus changes so it can track
/// which of the two panes is active and route Tab between them.
@MainActor
protocol PanelHost: ClosedTabHost {
    func panelDidBecomeActive(_ panel: PanelViewController)
    func panelRequestsFocusSwitch(_ panel: PanelViewController)
    /// The opposite pane — the default destination for a copy/move (F5/F6), whose
    /// current directory receives the operation. `nil` if there is no counterpart.
    func panelCounterpart(of panel: PanelViewController) -> PanelViewController?
    /// Enqueue a byte-moving operation (copy/move) on the window's shared background
    /// queue (PLAN.md §M2 `FileOperationQueue`). Fire-and-forget from the pane's view:
    /// the window's queue bar shows progress and both panes re-list as jobs finish.
    /// When `conflictPolicy` is `.ask`, `resolveConflict` fields each collision (TC's per-file
    /// conflict dialog) and `onError` fields each failure (skip/retry/abort); both run on the
    /// background copy thread, bridged to main-actor prompts (`ConflictPrompter`/`ErrorPrompter`).
    func enqueue(
        _ operation: FileOperation,
        conflictPolicy: ConflictPolicy,
        resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?
    )

    /// Queue `operations` in this order, then return once the window's queue has nothing left to do.
    /// A sync's record is kept after its copies have landed, and `enqueue` cannot say when that is.
    func runToCompletion(
        _ operations: [FileOperation],
        conflictPolicy: ConflictPolicy,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?
    ) async

    /// Record a completed, reversible operation (New Folder, rename, Move-to-Trash) on the
    /// window's shared undo journal so Cmd+Z can reverse it (PLAN.md §M2 "Undo journal").
    /// Copy/move are recorded by the window as their queue jobs finish, not here.
    func recordUndoableAction(_ record: UndoRecord)

    /// Record a completed marking change on the same journal so Cmd+Z reverses it too. `pane` is the
    /// pane that changed and `previousMarks` its marks *before*; `directory` is the folder they
    /// belong to — the current one, or a *departed* folder a navigation cleared them from.
    func recordSelectionChange(
        on pane: PanelViewController,
        directory: VFSPath,
        previousMarks: Set<VFSPath>,
        label: UndoActionLabel
    )

    /// Take back the marking change `recordSelectionChange` just journaled with these same values,
    /// as though it had never been recorded: the first click of a Cmd-double-click, whose mark the
    /// second click removes again. Call it before the marks go back. `false` when that change is no
    /// longer the newest entry, in which case nothing was taken back.
    func withdrawSelectionChange(
        on pane: PanelViewController,
        directory: VFSPath,
        previousMarks: Set<VFSPath>,
        label: UndoActionLabel
    ) -> Bool

    /// Reverse the most recent operation on the window's undo journal (Cmd+Z). Refreshes
    /// both panes and reports anything that couldn't be put back.
    func undoLastOperation()

    /// Re-apply the most recently undone operation (Cmd+Shift+Z). Refreshes both panes and
    /// reports anything that couldn't be re-applied.
    func redoLastOperation()

    /// The label of the action Cmd+Z would reverse next, for the menu title, or `nil` when
    /// the journal is empty. `DirnexCore` data — the app joins it to a translation.
    var nextUndoLabel: UndoActionLabel? { get }

    /// The label of the action Cmd+Shift+Z would re-apply next, or `nil` when there's nothing
    /// to redo.
    var nextRedoLabel: UndoActionLabel? { get }

    /// Capture both panes' current tabs into a named workspace (PLAN.md §M3 "Workspaces").
    /// The window owns this because a workspace spans both panes, which a single pane can't see.
    func captureWorkspace(named name: String) -> Workspace

    /// Restore both panes from a saved workspace, replacing their tab sets, then focus the
    /// left pane. Directories that have since vanished are dropped as the panes rebuild.
    func applyWorkspace(_ workspace: Workspace)

    /// Close Quick View outright, whatever size it is showing at — Esc's exit, which must land on
    /// the file list rather than stepping down to a smaller preview.
    func closeQuickView()

    /// Show the previewed file in `style`, as its `1` / `2` key does — a click on the header of the
    /// ⌃Q surface, which sits in the covered pane while the window owns the preference.
    func setQuickViewRenderStyle(_ style: QuickViewRenderStyle)

    /// Move a full-size Quick View on by `steps` files, animated like the two-finger swipe (← / →).
    /// The window owns it because the preview surface being turned is the window's, not the pane's.
    func flipQuickView(steps: Int)

    /// Scroll the Quick View preview the user is looking at, whichever pane or size holds it (⇧-arrows).
    /// `false` when no preview is up, so the key can do what it does without one.
    func scrollQuickView(_ move: QuickViewScroll) -> Bool

    /// The size Quick View is currently showing at. Drives the three View-menu checkmarks, and
    /// tells the pane whether its file list is covered (see `QuickViewMode.isFullSize`).
    var quickViewMode: QuickViewMode { get }

    /// Whether Quick View is currently on at any size.
    var isQuickViewEnabled: Bool { get }

    /// The active pane reports its cursor (or directory) changed so the window can re-drive
    /// the inactive pane's Quick View preview. A no-op unless Quick View is on and `panel`
    /// is the active pane.
    func panelCursorDidChange(_ panel: PanelViewController)

    /// A pane's directory (or active tab) changed. Lets the window bring the terminal drawer along
    /// when that pane is the active one.
    func panelDidNavigate(_ panel: PanelViewController)

    /// Record that a pane's listing of `path` landed, in the app-wide frecency index behind the path
    /// bar's fuzzy jump (PLAN.md §M3). Reached through the host rather than `FrecencyStore.shared`
    /// so a pane built in a test, which has no window, cannot write into the developer's own index.
    /// Before, 280 test fixture folders had built up there, counting toward the rank budget that
    /// ages real visits out (docs/NOTES.md ▸ Testing).
    func recordFrecencyVisit(_ path: VFSPath)

    /// Open a vault in `pane`, unlocking it first if it is locked (PLAN.md §M19). The window owns the
    /// unlock funnel — the sidebar click, the Unlock command, Enter on a saved vault's image and the
    /// right-click's Unlock Vault are one gesture as far as the user is concerned — so the pane hands
    /// the vault over rather than growing a second copy of it.
    ///
    /// `inNewTab` opens it in a new tab of `pane`, which is then the *other* pane (Cmd+Return on the
    /// image), and leaves the focus in the pane that asked.
    func panelRequestsVaultOpen(
        _ vault: VaultLocation,
        showingIn pane: PanelViewController,
        inNewTab: Bool
    )

    /// The window's shared cache of archive members extracted for preview (Quick Look / Quick
    /// View inside a browsed archive). Owned by the window so both panes and both preview
    /// surfaces resolve the same extracted temp file.
    var archivePreviewCache: ArchivePreviewCache { get }

    /// The window's shared record of nested-archive mounts — where each archive-inside-an-archive
    /// was extracted from (PLAN.md §M4 "nested archives"). Owned by the window so a mount entered
    /// in one pane still resolves its outer chain (walk-out, breadcrumb) if browsed from either.
    var nestedArchiveRegistry: NestedArchiveRegistry { get }

    /// The window's shared record of which encrypted archives have been unlocked this session
    /// (PLAN.md §M19). Owned by the window so a passphrase typed to preview a member also opens it,
    /// extracts it with F5, and enters a nested archive inside it — from either pane.
    var archivePassphrases: ArchivePassphraseStore { get }

    /// The window's record of archive members and remote files opened for editing, watched so a save
    /// can be offered back where it came from (PLAN.md §M4 write-back, §M21 Slice 10). Owned by the
    /// window because an edit outlives whatever the panes are showing — the tab that started it may
    /// be long gone by the time the user saves.
    var editedFiles: EditedFileRegistry { get }

    /// The window's copies of remote files pulled down for preview, opening or editing
    /// (PLAN.md §M21 Slice 10). Owned by the window for the same reason, and shared by both panes so
    /// previewing an object and then opening it costs one transfer.
    var remoteFileCache: RemoteFileCache { get }

    /// Queue a download of `entries` and report back when it has finished, however it finished
    /// (PLAN.md §M24 Slice 3). The copies are filed in ``remoteFileCache`` before `then` runs.
    ///
    /// On the host rather than in the pane because all three things it needs are the window's: the
    /// queue that gives an N-file transfer a determinate bar, Stop and pause; the cache the copies
    /// go into; and a lifetime that outlasts the pane, since a marked set of remote objects is
    /// minutes during which the user may change tabs or navigate away and is still owed an answer.
    func materializeRemoteFiles(
        _ entries: [FileEntry],
        then: @escaping @MainActor (OperationReport) -> Void
    )
}
