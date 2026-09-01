import AppKit
import DirnexCore

/// The main window: two file panes side by side with a draggable divider, exactly
/// one of them active at a time. Owns focus routing (Tab switches panes) and the
/// active-pane bookkeeping the panes themselves stay ignorant of.
@MainActor
final class BrowserWindowController: NSWindowController, PanelHost {
    let leftPanel: PanelViewController
    let rightPanel: PanelViewController
    // Internal for `BrowserWindowController+Sidebar` (⌥⌘S focus reveals then focuses); both set in `loadView`.
    let sidebar = SidebarViewController()
    var sidebarSplitItem: NSSplitViewItem!
    /// Outer split `[sidebar, panes]`; subclassed so hiding the focused sidebar returns focus to a
    /// pane (§M8). Internal, not private: `BrowserWindowController+QuickView` locks its divider
    /// while a full-screen preview covers it, and Swift's `private` is per-file.
    let splitViewController = SidebarFocusSplitViewController()
    /// Inner split: `[leftPanel, rightPanel]`. Kept separate so the sidebar toggle can't
    /// steal width from just the adjacent pane — the two panes redistribute proportionally in
    /// both directions here, holding their ratio across any number of sidebar toggles.
    /// Internal (not private) so `BrowserWindowController+Terminal` can stack it over the
    /// drawer — Swift's `private` is per-file.
    let panesSplitViewController = LockableDividerSplitViewController()
    /// Middle split: `[panes, terminal drawer]`, stacked vertically. Sits between the outer
    /// sidebar split and the panes split so the drawer spans the two panes and *not* the
    /// sidebar — Xcode's debug area, not a full-width strip — and so the sidebar stays full
    /// height beside it. Internal for `BrowserWindowController+Terminal` (Swift's `private` is
    /// per-file).
    let paneStackSplitViewController = LockableDividerSplitViewController()
    /// The shell drawer under the panes (PLAN.md §M6), and its split item so ⌃` can collapse
    /// and expand it. The view controller is built with the window but its shell isn't spawned
    /// until the drawer is first opened — see `TerminalDrawerViewController`.
    let terminalDrawer = TerminalDrawerViewController()
    var terminalDrawerItem: NSSplitViewItem!
    /// Set at launch when no drawer geometry is saved; consumed on the first open to give the
    /// drawer a usable height rather than AppKit's fallback (its minimum thickness — a four-line
    /// sliver). Same shape as `shouldCenterPanesDivider`, and for the same reason: a fresh install
    /// has no autosave entry, and that absence is the only signal that this is the first time.
    var shouldSizeTerminalDrawer = false
    /// Internal (not private) so `BrowserWindowController+QuickView` can tell which pane shows
    /// the list and which the preview.
    weak var activePanel: PanelViewController?
    /// The pane commands and the titlebar Back/Forward buttons act on: the focused one, falling
    /// back to the left pane before either has taken focus.
    var focusedPanel: PanelViewController { activePanel ?? leftPanel }

    /// What size Quick View is showing at in this window — off, the inactive pane (⌃Q, PLAN.md
    /// §M4), across both panes (⌃⇧Q) or filling the screen (⌃⌥Q, both §M11). Owned here because
    /// the mode spans both panes and follows whichever is active; driven from
    /// `BrowserWindowController+QuickView`.
    var quickViewMode: QuickViewMode = .off

    /// The two full-size preview surfaces, built on first use and then kept (hidden) for the life
    /// of the window: one pinned over the panes split, one over the window's whole content view.
    /// Internal for `BrowserWindowController+QuickViewFullSize`, which builds and places them.
    var fullWindowPreview: QuickViewPreviewView?
    var fullScreenPreview: QuickViewPreviewView?
    /// Whether *this window was put* into the native full-screen space by ⌃⌥Q, and so should come
    /// back out when the mode closes. Without it, closing the preview evicts a user who was
    /// already full-screen before they ever pressed the key.
    var didEnterFullScreenForQuickView = false

    /// How far a two-finger swipe had traveled when the fingers left the trackpad, held only for
    /// the frame or two it takes to read which way the system then moves — see
    /// `trackQuickViewSwipe`. `nil` whenever no gesture is being finished.
    var quickViewSwipeAmountAtLift: CGFloat?

    /// Archive members extracted for preview (Quick Look ⌘Y / Quick View ⌃Q inside a browsed
    /// archive), shared across both panes and both surfaces (PLAN.md §M4 "Quick Look inside").
    let archivePreviewCache = ArchivePreviewCache()

    /// The passphrases given for encrypted archives this session, so previewing, opening and
    /// extracting from one asks once rather than once per gesture (PLAN.md §M19). In memory only.
    let archivePassphrases = ArchivePassphraseStore()

    /// Archive members and remote files the user has opened for editing, watched so a save can be
    /// offered back where it came from (PLAN.md §M4 write-back, §M21 Slice 10). Wired to its handler
    /// in `windowDidLoad`.
    let editedFiles = EditedFileRegistry()

    /// Remote files pulled down for preview, opening or editing (PLAN.md §M21 Slice 10), shared
    /// across both panes and every surface — so ⌘Y then ⏎ then F4 on one object costs one transfer.
    let remoteFileCache = RemoteFileCache()

    /// Where each nested-archive mount was extracted from, shared across both panes so walking out
    /// of and breadcrumbing an archive-inside-an-archive resolves its outer chain (PLAN.md §M4
    /// "nested archives").
    let nestedArchiveRegistry = NestedArchiveRegistry()

    /// Local key monitor for the two keys Quick View must take back no matter where focus sits in
    /// this window (i.e. after the user clicked into the preview): Esc, which closes the mode, and a
    /// bare arrow, which walks the file list. A raw-event monitor rather than responder overrides
    /// because a focused `PDFView` may never translate Esc into `cancelOperation:`, and it and the
    /// preview's text view consume the arrows themselves. `nonisolated(unsafe)` so the nonisolated
    /// `deinit` can hand the token to `NSEvent.removeMonitor` — it's only ever touched on the main
    /// actor. Installed by `installQuickViewKeyMonitor()`, which lives with the rest of the Quick
    /// View machinery it serves (`BrowserWindowController+QuickView`) — hence internal rather than
    /// private.
    nonisolated(unsafe) var quickViewKeyMonitor: Any?

    /// Local scroll monitor for the two-finger swipe that flips files while a full-size Quick View
    /// is up (PLAN.md §M11); the gesture itself is the system's `NSEvent.trackSwipeEvent`. A
    /// raw-event monitor for the same reason as `quickViewKeyMonitor`: the preview's backends
    /// (`PDFView`, and `QLPreviewView` out of process) sit under the pointer and eat scroll before
    /// it bubbles.
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can hand the token back — it is only ever
    /// touched on the main actor. Installed by `installQuickViewSwipeMonitor()`.
    nonisolated(unsafe) var quickViewSwipeMonitor: Any?

    /// The shared background operation engine both panes route F5/F6 through, so copies and
    /// moves queue and run without blocking browsing (PLAN.md §M2). Volume-aware scheduling
    /// keys off the same `backend` the panes use.
    let queue: FileOperationQueue
    /// The window's undo journal owner (PLAN.md §M2). Records the panes' reversible
    /// operations — New Folder / rename / Trash inline, copy/move as their queue jobs finish
    /// — and reverses the most recent one on Cmd+Z. Persists across launches.
    let undoController: UndoController
    /// The window-bottom progress readout, collapsed to zero height while the queue is idle.
    let queueBar = QueueBarView()
    /// Internal, not private: `BrowserWindowController+ContainerLayout` builds it, and Swift's
    /// `private` is per-file.
    var queueBarHeight: NSLayoutConstraint!

    /// The Total-Commander-style function-key bar (PLAN.md §M6), pinned along the very bottom
    /// below the queue bar. Collapsed to zero height when `AppPreferences.showFunctionBar` is off
    /// — the same collapse mechanism the queue bar uses when idle.
    let functionBar = FunctionBarView()
    /// Internal (not private) so `BrowserWindowController+FunctionBar` can collapse/expand it —
    /// Swift's `private` is per-file.
    var functionBarHeight: NSLayoutConstraint!
    /// The long-lived task draining `queue.observe()` into the queue bar and pane refreshes.
    var queueObservation: Task<Void, Never>?
    /// Jobs already reacted to (panes re-listed, failures reported), so a repeat snapshot of
    /// the same finished job doesn't refresh twice. Cleared when the queue drains.
    var finalizedJobs: Set<OperationJobID> = []
    /// Where a queued `.materialize` job's report meets the gesture that asked for it
    /// (PLAN.md §M24 Slice 3) — see `BrowserWindowController+Materialize`.
    let materializeDeliveries = JobDeliveries()
    /// The same, for a queued `.writeBack` batch (PLAN.md §4 ▸ *Still open*, taken 2026-09-01) —
    /// see `BrowserWindowController+WriteBackBatch`. Its own instance rather than sharing the one
    /// above: they are keyed by job id and could not collide, and two names say which flow is
    /// waiting where one would leave a reader guessing.
    let writeBackDeliveries = JobDeliveries()
    /// Saves waiting to join the next write-back batch, and whether a gather is already running.
    ///
    /// Two properties rather than a type, because between them they *are* the pacing rule and it is
    /// three lines long: a save appends here, the gather takes everything and runs a batch, and
    /// whatever arrived meanwhile is waiting when it comes back round. The flag is what stops a
    /// second gather starting beside the first — with two, the same copy could be written back
    /// twice.
    ///
    /// **`EditedFile`, not a destination-specific pair**, because the split into "up to a server"
    /// and "back into an archive" happens *after* gathering: both endings were paying for a
    /// forty-file script one save at a time, so both wanted the same pacing and neither should own
    /// a copy of it (`+WriteBack`).
    var pendingWriteBacks: [EditedFile] = []
    var isGatheringWriteBacks = false
    /// The last observed pause state, so the queue bar's button knows which way to toggle.
    var lastPaused = false

    /// Autosave name for the panes split's divider geometry. A fresh install (or one still
    /// on the pre-V2 name) has no saved entry, which is our signal to open the panes 50/50
    /// rather than let AppKit squeeze the right pane to its minimum width.
    private static let panesAutosaveName = "BrowserPanesV2"
    /// Set at launch when no panes geometry is saved; consumed on first `showWindow` to
    /// center the divider once. A later user drag persists under `panesAutosaveName` and
    /// wins on subsequent launches.
    private var shouldCenterPanesDivider = false

    /// The trailing titlebar back/forward controls — the ⌘[ / ⌘] history commands (View ▸ Go) as
    /// two borderless chevron buttons, no bezel behind them. Held so a navigation, tab switch, or
    /// focus change can re-validate each button's enabled state against the active pane's trail
    /// (`updateNavigationButtons`).
    let backButton = NSButton()
    let forwardButton = NSButton()

    /// The leading titlebar button — right of the sidebar toggle — that appears only while a Sparkle
    /// update is waiting: the ambient counterpart to Sparkle's one-shot dialog. Held so
    /// `updateAvailabilityDidChange` can show, hide, and re-tooltip it
    /// (`BrowserWindowController+Updates`).
    let updateIndicatorButton = NSButton()

    init() {
        // A composite backend so a pane can browse into an archive (`archive:…` paths route
        // to a lazily-mounted read-only `ArchiveBackend`) while every local path still runs
        // through `LocalBackend` unchanged — including the shared queue and undo journal.
        let backend = CompositeBackend(local: LocalBackend())
        queue = FileOperationQueue(backend: backend, plainPackWriter: ArchivePacker())
        undoController = UndoController(backend: backend)
        let home = VFSPath.local(NSHomeDirectory())
        // Each pane restores its own tabs from the last session, keyed by side — unless the
        // user has turned session restore off (General settings), in which case both panes
        // open fresh at Home. The panes still persist their tabs so the setting can be
        // toggled back on without losing them.
        let restoreSession = AppPreferences.shared.restoreSession
        leftPanel = PanelViewController(
            backend: backend,
            restoration: restoreSession ? TabPersistence.load(paneKey: "left") : nil,
            defaultPath: home,
            restorationKey: "left"
        )
        rightPanel = PanelViewController(
            backend: backend,
            restoration: restoreSession ? TabPersistence.load(paneKey: "right") : nil,
            defaultPath: home,
            restorationKey: "right"
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dirnex"
        window.minSize = NSSize(width: 640, height: 360)

        // Modern chrome (like Notes/Xcode/Claude): no visible title bar. The content —
        // the vibrant sidebar and the two panes — runs edge-to-edge to the top of the
        // window, with the traffic lights floating over the sidebar. The title bar space
        // becomes usable window height instead of a dead strip. A leading titlebar
        // accessory (installed below) puts a sidebar show/hide button beside the traffic
        // lights; pane and sidebar content inset themselves below this zone via the safe
        // area, so nothing hides under the buttons.
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        super.init(window: window)

        // Read this before the split view lays out (which writes its autosave): a missing
        // entry means a first launch, so the divider should open centered.
        let panesGeometryKey = "NSSplitView Subview Frames \(Self.panesAutosaveName)"
        shouldCenterPanesDivider = UserDefaults.standard.object(forKey: panesGeometryKey) == nil

        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = "BrowserSplit"

        // The two panes live in their own split view, so the sidebar toggle only resizes this
        // group as a whole and the panes keep their 50/50 ratio (see `panesSplitViewController`).
        // A `HairlineSplitView` tints the inter-pane divider to match the column-header borders;
        // it must replace the default split view before any items are added (the setter clears
        // them). Setting it also re-adopts the controller as the split view's delegate.
        panesSplitViewController.splitView = HairlineSplitView()
        panesSplitViewController.splitView.isVertical = true
        panesSplitViewController.splitView.dividerStyle = .thin
        panesSplitViewController.splitView.autosaveName = Self.panesAutosaveName
        for panel in [leftPanel, rightPanel] {
            let item = NSSplitViewItem(viewController: panel)
            item.holdingPriority = NSLayoutConstraint.Priority(250)
            item.canCollapse = false
            panesSplitViewController.addSplitViewItem(item)
            panel.host = self
        }

        // The places/volumes strip leads, then the panes group. It's a real macOS sidebar
        // (vibrant, collapsible via View ▸ Show Sidebar) that drives the active pane.
        sidebar.delegate = self
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)
        sidebarSplitItem = sidebarItem
        splitViewController.onFocusedCollapse = { [weak self] in self?.focusedPanel.focusTable() }

        installTerminalDrawer()
        // The pane stack and the function-key bar share one column so the bar aligns with the
        // panes and never overlaps the sidebar — the sidebar stays full height beside it, exactly
        // as the terminal drawer does (both live inside this second split item, not the window).
        let panesItem = NSSplitViewItem(viewController: makePaneColumnController())
        panesItem.canCollapse = false
        splitViewController.addSplitViewItem(panesItem)

        // Assigning `contentViewController` resizes the window to the content view's
        // fitting size, discarding the initializer's `contentRect`. So set our default
        // size afterwards, then let a previously autosaved frame win if one exists.
        window.contentViewController = makeContainerViewController()
        if !window.setFrameUsingName("MainWindow") {
            window.setContentSize(NSSize(width: 1300, height: 750))
            window.centerOnScreen()
        }
        window.setFrameAutosaveName("MainWindow")

        // `installUpdateIndicator` only prepares its button; the two accessory installers below
        // place it — into the leading accessory beside the sidebar toggle.
        installUpdateIndicator()
        installSidebarToggle()
        installNavigationButtons()

        queueBar.onPauseToggle = { [weak self] in self?.togglePause() }
        queueBar.onCancelAll = { [weak self] in self?.cancelAllJobs() }
        queueBar.onCancelJob = { [weak self] id in self?.cancelJob(id) }
        queueBar.onPreferredHeightChanged = { [weak self] in self?.updateQueueBarHeight() }
        startObservingQueue()
        installQuickViewSupport()
        installQuickLookSheetGuard()
        observeVolumeUnmount()
        installFunctionBar()
        editedFiles.onEdited = { [weak self] edit in self?.offerWriteBack(edit) }
    }

    /// Put a sidebar show/hide button immediately to the right of the traffic lights, in
    /// the otherwise-empty transparent title bar, and the update indicator immediately right of
    /// *that*. A `.leading` titlebar accessory is the standard slot for both; the sidebar button
    /// drives the split controller's `toggleSidebar`, the same action as View ▸ Show Sidebar (⌃⌘S).
    ///
    /// Assumes `installUpdateIndicator` has already prepared its button (behavior + size); this
    /// only places it. The row is pinned at its *leading* edge so the sidebar toggle keeps its spot
    /// beside the traffic lights whether or not an update is waiting, and the indicator — hidden at
    /// rest, and `NSStackView` detaches hidden arranged subviews — leaves no gap behind it.
    private func installSidebarToggle() {
        let button = NSButton()
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "sidebar.leading",
            accessibilityDescription: String(
                localized: "Toggle Sidebar",
                comment: "Accessibility label for the sidebar toggle button."
            )
        )
        button.image?.isTemplate = true
        button.toolTip = String(
            localized: "Hide or show the sidebar",
            comment: "Tooltip for the sidebar toggle button."
        )
        button.target = splitViewController
        button.action = #selector(NSSplitViewController.toggleSidebar(_:))
        button.translatesAutoresizingMaskIntoConstraints = false

        let inset: CGFloat = 8
        let spacing: CGFloat = 12
        let sidebarWidth: CGFloat = 24
        let stack = NSStackView(views: [button, updateIndicatorButton])
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The accessory clips to this frame, so it has to be wide enough for both buttons even
        // while the indicator is hidden — a container sized for one alone would cut the badge off
        // on the day it appears. `updateIndicatorButton` carries its own 16pt width.
        let width = inset + sidebarWidth + spacing + 16 + inset
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: sidebarWidth),
            button.heightAnchor.constraint(equalToConstant: 22),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset)
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .leading
        window?.addTitlebarAccessoryViewController(accessory)
    }

    deinit {
        queueObservation?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let quickViewKeyMonitor { NSEvent.removeMonitor(quickViewKeyMonitor) }
        if let quickViewSwipeMonitor { NSEvent.removeMonitor(quickViewSwipeMonitor) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Show or collapse the queue bar. Driven by the queue observation: shown while any job
    /// is waiting/running/paused, collapsed to zero height (and hidden) once idle.
    func setQueueBar(visible: Bool) {
        guard queueBar.isHidden == visible else { return }
        queueBar.isHidden = !visible
        queueBarHeight.constant = visible ? queueBar.preferredHeight : 0
    }

    /// Follow the queue bar's height as its per-job list expands or collapses. Only adjusts
    /// while the bar is shown; `setQueueBar(visible:)` owns the collapse-to-zero when idle.
    func updateQueueBarHeight() {
        guard !queueBar.isHidden else { return }
        queueBarHeight.constant = queueBar.preferredHeight
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if shouldCenterPanesDivider {
            shouldCenterPanesDivider = false
            centerPanesDivider()
        }
        // A drawer the autosave restored open is one the user left open, so its shell starts with
        // the window. A fresh install opens collapsed and spawns nothing.
        startTerminalShellIfDrawerIsOpen()
        // Restore focus to whichever pane the user last left active — gated on the same session-
        // restore setting as the tabs, so a fresh session (setting off, or a first launch) opens on
        // the left as before.
        let restoredSide = AppPreferences.shared.restoreSession ? TabPersistence.loadActivePane() : nil
        let initialPanel = restoredSide == "right" ? rightPanel : leftPanel
        setActive(initialPanel)
        initialPanel.focusTable()
    }

    /// Split the two panes 50/50. Called once on a fresh layout (no saved divider
    /// geometry), after the window is on screen so the split view has its real width.
    private func centerPanesDivider() {
        let splitView = panesSplitViewController.splitView
        splitView.layoutSubtreeIfNeeded()
        let available = splitView.bounds.width - splitView.dividerThickness
        guard available > 0 else { return }
        splitView.setPosition(available / 2, ofDividerAt: 0)
    }

    // MARK: - PanelHost

    func panelDidBecomeActive(_ panel: PanelViewController) {
        setActive(panel)
    }

    func panelRequestsFocusSwitch(_ panel: PanelViewController) {
        counterpart(of: panel).focusTable()
    }

    func panelCounterpart(of panel: PanelViewController) -> PanelViewController? {
        counterpart(of: panel)
    }

    func panelDidNavigate(_ panel: PanelViewController) {
        updateNavigationButtons()
        // The drawer follows the *active* pane; the other one moving (a background refresh, a
        // completed copy re-listing it) is none of the shell's business.
        if panel === focusedPanel { syncTerminalToActivePanel() }
    }

    /// The other pane — the one a copy/move lands in, and the one Quick View previews into.
    /// Internal (not private) so `BrowserWindowController+QuickView` can reach it.
    func counterpart(of panel: PanelViewController) -> PanelViewController {
        panel === leftPanel ? rightPanel : leftPanel
    }

    /// Persist both panes' tabs on the way down (called from `applicationWillTerminate`). Navigation
    /// and tab/column changes already persist as they happen, but a cursor move or a mark toggle does
    /// not — so this is what captures the *final* cursor position and selection at quit, which is the
    /// state the user expects restored on next launch.
    func persistTabState() {
        leftPanel.persistState()
        rightPanel.persistState()
        // Which side had focus, so the next launch restores it rather than always snapping to left.
        TabPersistence.saveActivePane(focusedPanel.restorationKey ?? "left")
    }

    private func setActive(_ panel: PanelViewController) {
        guard activePanel !== panel else { return }
        activePanel?.isActivePanel = false
        panel.isActivePanel = true
        activePanel = panel
        // The titlebar Back/Forward buttons follow whichever pane is focused (⌘[ / ⌘] do too).
        updateNavigationButtons()
        // Tab-ing to the other pane moves the shell too: the drawer tracks the active pane, not
        // the pane it happened to be spawned from.
        syncTerminalToActivePanel()
        // The preview always sits opposite the active pane, so a focus switch swaps which pane
        // shows its list and which shows the preview.
        if isQuickViewEnabled { updateQuickView() }
    }
}
