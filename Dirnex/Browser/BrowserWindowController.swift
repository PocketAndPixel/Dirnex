import AppKit
import DirnexCore

/// The main window: two file panes side by side with a draggable divider, exactly
/// one of them active at a time. Owns focus routing (Tab switches panes) and the
/// active-pane bookkeeping the panes themselves stay ignorant of.
@MainActor
final class BrowserWindowController: NSWindowController, PanelHost {
    let leftPanel: PanelViewController
    let rightPanel: PanelViewController
    private let sidebar = SidebarViewController()
    /// Outer split: `[sidebar, panes]`. Collapsing/expanding the sidebar only ever resizes
    /// the panes group as a whole.
    private let splitViewController = NSSplitViewController()
    /// Inner split: `[leftPanel, rightPanel]`. Kept separate so the sidebar toggle can't
    /// steal width from just the adjacent pane — the two panes redistribute proportionally in
    /// both directions here, holding their ratio across any number of sidebar toggles.
    /// Internal (not private) so `BrowserWindowController+Terminal` can stack it over the
    /// drawer — Swift's `private` is per-file.
    let panesSplitViewController = NSSplitViewController()
    /// Middle split: `[panes, terminal drawer]`, stacked vertically. Sits between the outer
    /// sidebar split and the panes split so the drawer spans the two panes and *not* the
    /// sidebar — Xcode's debug area, not a full-width strip — and so the sidebar stays full
    /// height beside it. Internal for `BrowserWindowController+Terminal` (Swift's `private` is
    /// per-file).
    let paneStackSplitViewController = NSSplitViewController()
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

    /// Quick View (⌃Q) on/off for this window. When on, the inactive pane shows a live Quick
    /// Look preview of the file under the active pane's cursor (PLAN.md §M4). Owned here
    /// because the mode spans both panes and follows whichever is active; driven from
    /// `BrowserWindowController+QuickView`.
    var isQuickViewOn = false

    /// Archive members extracted for preview (Quick Look ⌘Y / Quick View ⌃Q inside a browsed
    /// archive), shared across both panes and both surfaces (PLAN.md §M4 "Quick Look inside").
    let archivePreviewCache = ArchivePreviewCache()

    /// Where each nested-archive mount was extracted from, shared across both panes so walking out
    /// of and breadcrumbing an archive-inside-an-archive resolves its outer chain (PLAN.md §M4
    /// "nested archives").
    let nestedArchiveRegistry = NestedArchiveRegistry()

    /// Local key monitor that lets Esc close Quick View no matter where focus sits in this
    /// window (e.g. after the user clicked into the preview). A raw-event monitor rather than a
    /// `cancelOperation:` override because a focused `PDFView` may never translate the Esc key
    /// into that action, so the message would never bubble. `nonisolated(unsafe)` so the
    /// nonisolated `deinit` can hand the token to `NSEvent.removeMonitor` — it's only ever
    /// touched on the main actor. See `installEscapeMonitor()`.
    nonisolated(unsafe) private var escapeMonitor: Any?

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
    private var queueBarHeight: NSLayoutConstraint!

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

    /// The trailing titlebar button that toggles hidden files app-wide (the ⇧⌘. command in
    /// button form). Held so `showHiddenDidChange` can restyle it to track the current state.
    let hiddenToggleButton = NSButton()

    /// The leading titlebar back/forward control beside the sidebar toggle — the ⌘[ / ⌘] history
    /// commands (View ▸ Go) as a two-segment pill, the same control Finder/Safari use. Held so a
    /// navigation, tab switch, or focus change can re-validate each segment's enabled state
    /// against the active pane's trail (`updateNavigationButtons`).
    let navigationControl = NSSegmentedControl()

    init() {
        // A composite backend so a pane can browse into an archive (`archive:…` paths route
        // to a lazily-mounted read-only `ArchiveBackend`) while every local path still runs
        // through `LocalBackend` unchanged — including the shared queue and undo journal.
        let backend = CompositeBackend(local: LocalBackend())
        queue = FileOperationQueue(backend: backend)
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
            window.center()
        }
        window.setFrameAutosaveName("MainWindow")

        installSidebarToggle()
        installNavigationButtons()
        installHiddenToggle()

        queueBar.onPauseToggle = { [weak self] in self?.togglePause() }
        queueBar.onCancelAll = { [weak self] in self?.cancelAllJobs() }
        queueBar.onCancelJob = { [weak self] id in self?.cancelJob(id) }
        queueBar.onPreferredHeightChanged = { [weak self] in self?.updateQueueBarHeight() }
        startObservingQueue()
        installEscapeMonitor()
        observeVolumeUnmount()
        installFunctionBar()
    }

    /// Esc closes Quick View from anywhere in this window. A window-scoped local monitor sees the
    /// raw key event ahead of responder dispatch, so it works even when the focused view (the
    /// preview `PDFView`) would otherwise swallow the key. It deliberately stands aside for the
    /// responders that own Esc themselves: a focused file table runs its progressive Esc (clear
    /// filter → close Quick View → clear marks) via `fileTableCancel`, and a text field editor
    /// cancels the edit. Only fires while this window is key, so a sheet, the ⌘K palette, or the
    /// Settings window keep their own Esc.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == 53, // Esc
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
                  window?.isKeyWindow == true,
                  isQuickViewOn
            else { return event }
            let responder = window?.firstResponder
            // A file table or a text edit owns Esc for its own purpose — let the event through.
            if responder is FileTableView || responder is NSText { return event }
            // So does the terminal drawer, far more so: Esc is `vim`'s entire modal interface, and
            // a monitor that swallowed it to close a preview would make the drawer useless for the
            // editor most likely to be running in it.
            if isTerminalFocused { return event }
            toggleQuickView()
            return nil
        }
    }

    /// Put a sidebar show/hide button immediately to the right of the traffic lights, in
    /// the otherwise-empty transparent title bar. A `.leading` titlebar accessory is the
    /// standard slot for it; the button drives the split controller's `toggleSidebar`, the
    /// same action as View ▸ Show Sidebar (⌃⌘S).
    private func installSidebarToggle() {
        let button = NSButton()
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "sidebar.leading",
            accessibilityDescription: "Toggle Sidebar"
        )
        button.image?.isTemplate = true
        button.toolTip = "Hide or show the sidebar"
        button.target = splitViewController
        button.action = #selector(NSSplitViewController.toggleSidebar(_:))
        button.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            button.heightAnchor.constraint(equalToConstant: 22)
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
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
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
        setActive(leftPanel)
        leftPanel.focusTable()
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
        if isQuickViewOn { updateQuickView() }
    }
}

// MARK: - Container layout

// In a same-file extension so the two view-builders don't count toward the class's
// `type_body_length`; they still share the type's `private` scope and reach its stored properties.
private extension BrowserWindowController {
    /// Stack the sidebar-and-panes split over the queue bar, both full width. The function bar is
    /// *not* here — it lives inside the panes column (`makePaneColumnController`) so it aligns with
    /// the panes rather than spanning under the sidebar. `setQueueBar(visible:)` collapses the queue
    /// bar to zero while idle, handing its height back to the panes.
    func makeContainerViewController() -> NSViewController {
        let container = NSViewController()
        container.view = NSView()
        container.addChild(splitViewController)

        let splitView = splitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        queueBar.translatesAutoresizingMaskIntoConstraints = false
        queueBar.isHidden = true
        container.view.addSubview(splitView)
        container.view.addSubview(queueBar)

        queueBarHeight = queueBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: queueBar.topAnchor),
            queueBar.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            queueBar.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            queueBar.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            queueBarHeight
        ])
        return container
    }

    /// The right-hand column of the outer sidebar split: the pane stack (two panes over the
    /// terminal drawer) with the function-key bar pinned along its bottom. Wrapping them together
    /// as the split's second item is what keeps the bar off the sidebar — the sidebar is the split's
    /// *first* item and stays full height beside this whole column. The window controller owns
    /// `functionBarHeight` and collapses it to zero when the feature is off.
    func makePaneColumnController() -> NSViewController {
        let column = NSViewController()
        column.view = NSView()
        column.addChild(paneStackSplitViewController)

        let paneStack = paneStackSplitViewController.view
        paneStack.translatesAutoresizingMaskIntoConstraints = false
        functionBar.translatesAutoresizingMaskIntoConstraints = false
        functionBar.isHidden = true
        column.view.addSubview(paneStack)
        column.view.addSubview(functionBar)

        functionBarHeight = functionBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            paneStack.topAnchor.constraint(equalTo: column.view.topAnchor),
            paneStack.leadingAnchor.constraint(equalTo: column.view.leadingAnchor),
            paneStack.trailingAnchor.constraint(equalTo: column.view.trailingAnchor),
            paneStack.bottomAnchor.constraint(equalTo: functionBar.topAnchor),
            functionBar.leadingAnchor.constraint(equalTo: column.view.leadingAnchor),
            functionBar.trailingAnchor.constraint(equalTo: column.view.trailingAnchor),
            functionBar.bottomAnchor.constraint(equalTo: column.view.bottomAnchor),
            functionBarHeight
        ])
        return column
    }
}

// MARK: - SidebarViewControllerDelegate

extension BrowserWindowController: SidebarViewControllerDelegate {
    /// A sidebar click points the active pane at the chosen place/volume, then hands
    /// keyboard focus back to that pane so browsing continues without a mouse.
    func sidebar(_ sidebar: SidebarViewController, didActivate path: VFSPath) {
        let target = activePanel ?? leftPanel
        target.navigate(to: path)
        target.focusTable()
    }

    /// A saved search re-runs its query in the active pane, opening the hits in a virtual
    /// results tab, then hands focus back so browsing the results continues without a mouse.
    func sidebar(_ sidebar: SidebarViewController, didActivateSavedSearch savedSearch: SavedSearch) {
        let target = activePanel ?? leftPanel
        target.runSavedSearch(savedSearch)
        target.focusTable()
    }

    /// A saved server connects (SFTP) or mounts (SMB) in the active pane and browses it. The
    /// connect/mount is async and, on completion, both navigates *and* focuses the pane itself,
    /// so grabbing focus here (before the connection resolves) would be premature.
    func sidebar(_ sidebar: SidebarViewController, didActivateServer server: ServerConnection) {
        (activePanel ?? leftPanel).connect(to: server)
    }

    /// A tag row searches for the files carrying it and shows them in the active pane, the way a
    /// saved search does — a tag is a query, not a place.
    func sidebar(_ sidebar: SidebarViewController, didActivateTag tag: FinderTag) {
        let target = activePanel ?? leftPanel
        target.runTagSearch(tag)
        target.focusTable()
    }

    /// "Edit…" on a saved server re-opens the connect prompt prefilled from it, in the active pane.
    func sidebar(_ sidebar: SidebarViewController, didEditServer server: ServerConnection) {
        (activePanel ?? leftPanel).editServer(server)
    }

    /// An empty-space / header click in the sidebar re-focuses the active pane so its keyboard
    /// focus — and the responder-chain file commands (F5/F6/F8) — survive the click.
    func sidebarDidClickEmptyArea(_ sidebar: SidebarViewController) {
        (activePanel ?? leftPanel).focusTable()
    }
}
