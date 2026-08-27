import AppKit
import DirnexCore

/// The pane's owner (the window controller) — receives focus changes so it can track
/// which of the two panes is active and route Tab between them.
@MainActor
protocol PanelHost: AnyObject {
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

    /// Quick View (⌃Q / ⌃⇧Q / ⌃⌥Q): switch to `mode`, or back to `.off` when it is already the
    /// current one — each key is a flat toggle that turns its own size off and switches from any
    /// other. The window owns the state because the mode spans both panes, which a single pane
    /// can't coordinate.
    func toggleQuickView(_ mode: QuickViewMode)

    /// Close Quick View outright, whatever size it is showing at — Esc's exit, which must land on
    /// the file list rather than stepping down to a smaller preview.
    func closeQuickView()

    /// Move a full-size Quick View on by `steps` files, animated like the two-finger swipe (← / →).
    /// The window owns it because the preview surface being turned is the window's, not the pane's.
    func flipQuickView(steps: Int)

    /// The size Quick View is currently showing at. Drives the three View-menu checkmarks, and
    /// tells the pane whether its file list is covered (see `QuickViewMode.isFullSize`).
    var quickViewMode: QuickViewMode { get }

    /// Whether Quick View is currently on at any size.
    var isQuickViewEnabled: Bool { get }

    /// The active pane reports its cursor (or directory) changed so the window can re-drive
    /// the inactive pane's Quick View preview. A no-op unless Quick View is on and `panel`
    /// is the active pane.
    func panelCursorDidChange(_ panel: PanelViewController)

    /// A pane's directory (or active tab) changed, so its back/forward trail may have. Lets the
    /// window re-validate the titlebar Back/Forward buttons against the active pane's history.
    func panelDidNavigate(_ panel: PanelViewController)

    /// Open a saved vault in `pane`, unlocking it first if it is locked (PLAN.md §M19). The window
    /// owns the unlock funnel — the sidebar click, the Unlock command and Enter on the image are one
    /// gesture as far as the user is concerned — so the pane hands the vault over rather than
    /// growing a second copy of it.
    func panelRequestsVaultOpen(_ vault: VaultLocation, showingIn pane: PanelViewController)

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

/// One file pane: a path bar, an `NSTableView` of the current directory, and a status
/// line. A thin renderer over a `DirnexCore.Panel` value (PLAN.md §2 "UI is a thin
/// client") — every navigation/selection decision lives in `Panel`; this class only
/// mirrors that state into AppKit and pushes user input back into it.
@MainActor
final class PanelViewController: NSViewController {
    // Internal so the tab-management extension in its own file can list directories.
    let backend: any VFSBackend
    /// This pane's open tabs and which one is showing. Only the tab code in
    /// `PanelViewController+Tabs` mutates these directly; everything else goes through
    /// `panel`, which forwards to the active tab.
    var tabs: [PanelTab]
    var activeTabIndex: Int
    /// The active tab's pane state. A computed forward, so every existing `panel.…`
    /// read and mutation transparently targets the current tab.
    var panel: Panel {
        get { tabs[activeTabIndex].panel }
        set { tabs[activeTabIndex].panel = newValue }
    }

    /// Stable identifier ("left"/"right") under which this pane's tabs are persisted
    /// across launches; `nil` disables persistence.
    var restorationKey: String?
    weak var host: PanelHost?

    var isActivePanel = false {
        didSet { updateActiveAppearance() }
    }

    /// Internal (not private) so the Quick Look extension in its own file can map the
    /// cursor row to a source frame for the zoom animation.
    let tableView = FileTableView()
    // Internal so the Quick View extension can pin its preview overlay over the file list.
    let scrollView = NSScrollView()

    /// The opaque preview surface that covers this pane's file list while it is the *inactive*
    /// pane and Quick View (⌃Q) is on — a live preview of the file under the *other* pane's
    /// cursor. Lazily built on first use; `nil` until then. The two full-size modes (§M11) host
    /// their own instances of the same view at their own anchors, owned by the window. Managed by
    /// `PanelViewController+QuickView`.
    var quickViewPreview: QuickViewPreviewView?
    // Internal so `PanelViewController+Chrome` can update them from its own file.
    let pathBar = PathBarView()
    let statusLabel = NSTextField(labelWithString: "")
    // The tab strip above the path bar; hidden until the pane has more than one tab.
    let tabBar = TabBarView()

    /// Guards the cursor⇄table-selection mirror against feedback loops: when we push
    /// `panel.cursor` into the table, the resulting selection-changed callback must
    /// not write it straight back. Internal for the table delegate in its own file.
    var isSyncingSelection = false
    /// Finder-style mouse-selection bookkeeping (see `PanelViewController+MouseSelect`).
    /// `mouseSelectionAnchor` is the entry a Shift-click range extends from;
    /// `mouseSelectionBase` is the mark set that predates the current range sweep, so a
    /// Shift-click keeps earlier Cmd-clicked marks. Both are view-only — `Panel` stays
    /// unaware — and identity-keyed so they survive a re-sort or refresh and self-heal
    /// when the anchor entry disappears. Reset on navigation and when the marks are cleared.
    var mouseSelectionAnchor: VFSPath?
    var mouseSelectionBase: Set<VFSPath> = []
    /// Guards the column-layout capture against feedback: applying a tab's stored widths
    /// and order itself posts resize/move notifications, which must not be recorded back
    /// as if the user had dragged them. Internal for `PanelViewController+Columns`.
    var isApplyingColumnLayout = false
    /// Identity of the entry currently being renamed inline (`nil` = not renaming). The
    /// name cell for this entry is built as an editable text field; everything else in
    /// `PanelViewController+Rename` drives the edit lifecycle. Internal so the table
    /// delegate in its own file can read it while building cells.
    var renamingEntryID: VFSPath?
    /// Set when the inline rename ends via Esc, so the shared end-editing handler reverts
    /// the field instead of committing the typed name. Internal for `+Rename`.
    var renameWasCancelled = false
    /// Set when a live background refresh (FSEvents, a directory-size total) arrived while an
    /// inline rename field was open and was therefore deferred — see `deferRefreshIfRenaming`.
    /// The end-editing handler replays it so the pane catches up on the change it skipped.
    /// Internal for `+Rename`.
    var renamePendingRefresh = false
    /// Bumped on every navigation so a slow listing that resolves after the user has
    /// already moved on is discarded instead of clobbering the current directory.
    /// Internal so `PanelViewController+Tabs` can discard a stale load on tab switch.
    var loadToken = 0
    /// Space-on-dir walks in flight over a **billed** backend, by the folder each is measuring —
    /// the handles `cancelUnwatchedDirectorySizeWalks` cancels when this pane stops looking
    /// (PLAN.md §M21 Slice 11). A local walk is deliberately absent: it is fire-and-forget by
    /// design, because finishing one costs nothing and banks a total (`DirectoryLoader.size`).
    /// Internal for `PanelViewController+Sizing`; a stored property cannot live in an extension.
    var directorySizeWalks: [VFSPath: Task<DirectoryLoader.SizeOutcome, Never>] = [:]
    /// Folders whose walk reached its budget and gave up. Kept apart from "never measured" so the
    /// size column can draw them differently — the two are indistinguishable otherwise, and the
    /// dash would invite a re-press that spends the whole budget again.
    var directorySizesGaveUp: Set<VFSPath> = []
    /// A short-lived message that outranks the computed item count in the status line — how a
    /// detached background action (an external diff launch) reports itself without stealing focus
    /// with an alert. `nil` when the line is showing its normal contents. Driven entirely by
    /// `PanelViewController+Chrome`; a stored property cannot live in that extension.
    var transientStatus: String?
    /// Bumped by each `showTransientStatus`, so a later message's expiry can't clear an earlier
    /// one's — the same stale-callback guard as `loadToken`.
    var transientStatusToken = 0
    /// FSEvents watcher for the directory on screen — live-refreshes the pane when the
    /// folder changes underneath us. Replaced on every navigation; `nil` for backends
    /// without the `.watch` capability. Internal (like `gitWatcher` below) because the code that
    /// drives it lives in `PanelViewController+Watch`; a stored property cannot.
    var watcher: DirectoryWatcher?
    /// What `watcher` is actually watching right now — the live stream's own paths, as opposed to
    /// `mergedSources`, which is the *active tab's* record of what its listing was gathered from.
    /// The two drift apart exactly when a pane's other tab takes the watcher over, which is why the
    /// rebuild guard in `watchMergedListing` reads this and not the tab's copy (PLAN.md §M8).
    var watchedSources: [VFSPath] = []
    /// The remote poll's loop, or `nil` when this pane is not talking to a server — a pane on the
    /// local disk, one nobody is looking at, or polling switched off in Settings. Driven entirely by
    /// `PanelViewController+RemoteRefresh`; a stored property cannot live in that extension.
    ///
    /// Held `[weak self]` inside rather than cancelled from `deinit`, which a `nonisolated deinit`
    /// cannot reach: the loop is one-shot-sleep-then-check, so a pane that goes away leaves at most
    /// one sleeping task holding a weak reference, which returns on its next wake.
    var remoteRefreshTask: Task<Void, Never>?
    /// The path `remoteRefreshTask` was armed for, so re-arming can be idempotent — a burst of
    /// occlusion notifications must not keep resetting the clock and starve the poll forever.
    var remoteRefreshScheduledFor: VFSPath?
    /// The last poll this pane completed: which directory it was of, what it cost, and when it
    /// finished. The cost is what `RemoteRefreshPolicy` spaces the next round by — an expensive
    /// folder backs off on its own — and the timestamp is what lets a pane uncovered after twenty
    /// minutes catch up at once while one flicked away and back does not bill a request for the
    /// gesture.
    ///
    /// **Carrying the path is what makes it survive its own teardown.** It began as a bare pair
    /// cleared whenever the armed path changed, and `stopRemoteRefresh` nils that path — so every
    /// stand-down threw the timings away and the catch-up above silently became "wait out a fresh
    /// interval". Invisible at a 15 s floor and an hour of staleness at an hour's; caught by
    /// watching the running app rather than by any test, which cannot arm a timer. Keyed by path
    /// there is nothing to clear: a measurement of another directory is simply not used.
    var remoteRefreshLastPoll: RemoteRefreshMeasurement?
    /// The window whose occlusion this pane is observing, so the registration can be re-pointed
    /// rather than duplicated. `weak` because the observation is the only thing that would keep a
    /// closed window alive, and a pane must not be that thing.
    weak var occlusionObservedWindow: NSWindow?
    /// FSEvents watcher for the *repository root* of the directory on screen, and the root it
    /// covers. Distinct from `watcher`, which re-lists this folder: what Git says about these rows
    /// also changes with the index and `HEAD` at the root — a `git add` in a terminal — and no
    /// event under this folder reports that. `nil` outside a repository. Managed by
    /// `PanelViewController+Git`, hence internal.
    var gitWatcher: DirectoryWatcher?
    var gitWatchedRoot: VFSPath?
    /// The visible cursor sits on the synthetic `..` row (which has no backing entry).
    /// Tracked in the UI only — `Panel` stays unaware of the parent row. Internal so the
    /// Quick Look extension can suppress previews while the cursor is on `..`; forwards
    /// to the active tab so each tab remembers whether it was parked on `..`.
    var cursorOnParentRow: Bool {
        get { tabs[activeTabIndex].cursorOnParentRow }
        set { tabs[activeTabIndex].cursorOnParentRow = newValue }
    }

    init(
        backend: any VFSBackend,
        restoration: PersistedPane?,
        defaultPath: VFSPath,
        restorationKey: String?
    ) {
        self.backend = backend
        self.restorationKey = restorationKey
        let layout = PanelViewController.restoredLayout(
            from: restoration,
            defaultPath: defaultPath,
            showHidden: AppPreferences.shared.showHidden
        )
        tabs = layout.tabs
        activeTabIndex = layout.activeIndex
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View setup

    override func loadView() {
        configureTable()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        pathBar.delegate = self
        tabBar.delegate = self

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        // A long status line (e.g. a big type-to-filter string) must truncate, never widen the
        // pane: a label defaults to a high horizontal compression resistance, which the enclosing
        // split view reads as a minimum width and honors by shoving the divider across. Drop it
        // so the pane's width wins and the text tail-truncates instead.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [tabBar, pathBar, scrollView, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        tabBar.setContentHuggingPriority(.required, for: .vertical)
        pathBar.setContentHuggingPriority(.required, for: .vertical)
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        // The pane fills the window to the top (the title bar is transparent and content
        // runs edge-to-edge). Pin the chrome stack's top to the safe-area guide so the tab
        // strip / path bar clear the traffic-light zone when the sidebar is collapsed and
        // this pane slides under the buttons; the sides and bottom stay flush.
        let container = PanelContainerView()
        // A click in the pane's chrome gaps (insets, spacing) must refocus the file table so the
        // responder-chain file commands (F5/F6/F8) stay live — see `PanelContainerView`.
        container.fileTable = tableView
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
    }

    private func configureTable() {
        // A contextual column (the size bar) is installed by the code that owns its condition, not
        // here — at setup nothing is known about the mode or the directory yet.
        for column in Column.allCases where !column.isContextual {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue)
            )
            tableColumn.title = column.title
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minWidth
            tableView.addTableColumn(tableColumn)
        }

        tableView.style = .plain
        // Only the Name column absorbs slack as the pane resizes; Size and Date keep their
        // set widths so they never scroll off-screen when a pane is narrow.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // The cell centers its icon/text vertically; the system default height leaves it cramped,
        // so give each row a little vertical breathing room above and below. How much is the
        // app-wide `rowDensity` (PLAN.md §M15) — `.regular` is the 22 pt this was hardcoded to.
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = AppPreferences.shared.rowDensity.rowHeight
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.inputDelegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        configureDragging()
        observeColumnLayoutChanges()
        updateSortIndicators()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeShowHiddenPreference()
        observeRowDensityPreference()
        observePalettePreference()
        observeFileColorRules()
        observeGitStatusChanges()
        observeFinderTagChanges()
        observeCloudSyncStatusChanges()
        observeDirectorySizeChanges()
        observeSizeVizDisplayModePreference()
        observeRemoteRefreshConditions()
        // The one activation nobody asked for: a restored tab is being opened because the app is
        // starting, not because anyone pressed anything. See `activateTab(unasked:)`.
        activateTab(unasked: true)
    }

    /// The pane has a window, so "is anybody looking" has an answer for the first time — at
    /// `viewDidLoad` there is no window and the remote poll correctly stands down. Occlusion changes
    /// after this are the observer's, but the *first* one is not guaranteed to arrive: a pane whose
    /// view is installed into a window that is already on screen has nothing to change.
    override func viewDidAppear() {
        super.viewDidAppear()
        observeWindowOcclusion()
        updateRemoteRefreshSchedule()
    }

    // MARK: - Focus

    func focusTable() {
        loadViewIfNeeded()
        view.window?.makeFirstResponder(tableView)
    }

    private func updateActiveAppearance() {
        pathBar.isActive = isActivePanel
        tabBar.isActivePane = isActivePanel
    }
}
