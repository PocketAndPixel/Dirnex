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

    /// The window's shared cache of archive members extracted for preview (Quick Look / Quick
    /// View inside a browsed archive). Owned by the window so both panes and both preview
    /// surfaces resolve the same extracted temp file.
    var archivePreviewCache: ArchivePreviewCache { get }

    /// The window's shared record of nested-archive mounts — where each archive-inside-an-archive
    /// was extracted from (PLAN.md §M4 "nested archives"). Owned by the window so a mount entered
    /// in one pane still resolves its outer chain (walk-out, breadcrumb) if browsed from either.
    var nestedArchiveRegistry: NestedArchiveRegistry { get }
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
        let restored = PanelViewController.restoredTabs(from: restoration)
        let showHidden = AppPreferences.shared.showHidden
        tabs = restored.isEmpty ? [PanelTab(path: defaultPath, showHidden: showHidden)] : restored
        activeTabIndex = restored.isEmpty
            ? 0
            : min(max(restoration?.activeIndex ?? 0, 0), restored.count - 1)
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
        // split view reads as a minimum width and honours by shoving the divider across. Drop it
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
        // A contextual column (the Git gutter) is installed by the code that owns its condition,
        // not here — at setup no directory has been listed yet, so nothing is known about it.
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
        // The cell centers its 16pt icon/text vertically; the system default height leaves
        // it cramped, so give each row a little vertical breathing room above and below.
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 22
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
        observeGitStatusChanges()
        observeFinderTagChanges()
        observeCloudSyncStatusChanges()
        observeDirectorySizeChanges()
        activateTab()
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

    // MARK: - Navigation

    /// Load `path` and install it in the active tab. When `focus` names a child that
    /// still exists (used when walking up), the cursor lands on it — the expected "go up,
    /// land on where I came from" behavior. A successful load records the visit in the tab's
    /// back/forward history (PLAN.md §M3) unless `recordHistory` is `false` — the flag
    /// back/forward/jump navigation passes so walking the trail doesn't append to it.
    /// Internal so `PanelViewController+Tabs` can load a freshly opened tab.
    func navigate(to path: VFSPath, focus child: VFSPath? = nil, recordHistory: Bool = true) {
        loadToken += 1
        let token = loadToken
        let tabIndex = activeTabIndex
        // Captured before the async load: was this tab showing a *non-re-listable* virtual pane
        // when we left? A `.search` results listing (and a browsed archive) can't be re-entered
        // from a history trail, so leaving one starts fresh. An SFTP location *is* re-listable, so
        // it keeps a normal back/forward trail like a local directory.
        let wasVirtual = panel.path.backend != .local && !panel.path.backend.isSFTP
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
                resetMouseSelectionAnchor()
                recordMarkChange(since: departedMarks, in: departed, label: .clearSelection)
                if let child, let index = panel.model.index(ofID: child) {
                    panel.moveCursor(to: index)
                }
                // Land on a real entry; only an empty directory parks the cursor on `..`.
                cursorOnParentRow = panel.isEmpty && panel.parentPath != nil
                tabs[tabIndex].hasLoaded = true
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
                startWatching(path)
                updateGitStatus()
                updateTagStatus()
                updateSyncStatus()
                updateSizeVisualization()
                persistState()
                host?.panelDidNavigate(self)
            } catch {
                guard token == loadToken else { return }
                presentLoadFailure(error, path: path)
            }
        }
    }
}
