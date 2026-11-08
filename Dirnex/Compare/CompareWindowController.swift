import AppKit
import DirnexCore

/// One side of a comparison as the window receives it: the file as lines, and what to call it.
struct CompareSource: Sendable {
    /// The file's name, over its pane.
    let name: String
    /// Where the file is, under its name.
    let detail: String
    /// Where the file lives: a server object's or an archive member's own location, never the copy
    /// read. A save names it to the Synchronize window, which compares that row again.
    let origin: VFSPath
    /// The file's lines, copies included (PLAN.md §M33).
    var document: ComparedDocument
    /// The grammar its syntax is colored by, or `nil` for none. Picked again when the file is read
    /// again (`+Watch`).
    var language: SyntaxLanguage?
    /// The local file a save writes, as it was read or last saved, or `nil` for a side this window
    /// cannot save (PLAN.md §M33 Slice 3). For a server file or an archive member it is the copy
    /// read, which the save writes before ``writeBack`` carries it there (Slice 4).
    var target: ComparedFileSave.Target?
    /// Where a save of the copy goes back to, or `nil` for a local file saved in place.
    var writeBack: EditDestination?
    /// Which file this is, on whichever side Swap Sides has put it. An undo finds its file by this.
    let id = UUID()
    /// What the window's undo files this file's copies under, so a file read again drops its own
    /// copies from Edit ▸ Undo and keeps the other file's (PLAN.md §M33 Slice 5).
    let undoTarget = CompareUndoTarget()
}

/// The object one file's copies are registered with in the compare window's undo manager.
/// `UndoManager.removeAllActions(withTarget:)` then reaches that file's copies and no other's:
/// probed 2026-10-25, it took one target's actions off both stacks and left the other's, titles
/// and order intact.
final class CompareUndoTarget: Sendable {}

/// The compare window, which takes clicks and keys while another window is modal.
///
/// The Synchronize window is app-modal and opens comparisons, and a plain window opened from it
/// draws but takes no click or key until the Synchronize window closes. Probed 2026-10-22 with a
/// modal session: a plain window's click was dropped, this one's arrived, and with no session both
/// did (PLAN.md §M31 Slice 4).
final class CompareWindow: NSWindow {
    override var worksWhenModal: Bool { true }
}

/// Dirnex's own compare window (PLAN.md §M31 Slice 3): two files side by side, level row for row,
/// the changes marked, and the keyboard going from one change to the next.
///
/// Everything it shows is `TextComparison`'s, computed off the main thread together with each pane's
/// text and syntax colors; the main thread only sets the text (`+Comparing`). Changing an option
/// computes it all again and keeps the same line of the left file at the top. So does a copy across
/// (`+Copy`, PLAN.md §M33), which changes one side's lines and compares the two again, and a file
/// that changed on disk (`+Watch`), which is read again.
@MainActor
final class CompareWindowController: NSWindowController, NSWindowDelegate {
    /// Windows on screen. A controller holds itself here until its window closes.
    private(set) static var open: [CompareWindowController] = []

    /// The file on the left, and the one on the right. Swap Sides exchanges them, and a copy changes
    /// one of their documents.
    var left: CompareSource
    var right: CompareSource
    /// Whether changes may be copied across at all. The conflict dialog's window takes none.
    let allowsCopies: Bool
    /// Where a save keeps its undo, and whose journal records it (`+Save`).
    let saving: CompareSaving
    /// Whether a save is running, which a second ⌘S waits out. A file that changed meanwhile is
    /// looked at once it ends (`+Watch`).
    var isSaving = false {
        didSet { if oldValue, !isSaving { lookAgainAfterSave() } }
    }

    /// Each file's watch, and the reads running on it (`+Watch`).
    let fileWatch = CompareFileWatch()
    /// Bumped whenever a save lands, so a comparison computed before it does not mark a saved side
    /// as edited.
    var savesLanded = 0
    /// The window's undo: Edit ▸ Undo reaches it through `NSWindow`, which asks the delegate for it.
    /// Each copy groups itself (`+Copy`), so it does not group by event.
    let edits: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    /// Bumped whenever what either side holds changes, by a copy, an undo or Swap Sides. A copy acts
    /// only on a comparison of the sides as they stand, which `comparedRevision` says this is.
    var sidesRevision = 0
    var comparedRevision = 0
    var comparison: TextComparison?
    var changeKinds: [CompareChangeKind] = []
    /// The change the band marks and the counter names, or `nil` for none (`+Changes`).
    var currentChange: Int?

    let toolbar = CompareToolbar()
    let banner = NSTextField(wrappingLabelWithString: "")
    let leftPane = ComparePaneView(side: .left)
    let rightPane = ComparePaneView(side: .right)
    /// Each side's pane, left first.
    var panes: [(side: ComparisonPaneText.Side, pane: ComparePaneView)] {
        [(.left, leftPane), (.right, rightPane)]
    }

    let band = CompareBandView()
    let overview = CompareOverviewView()
    /// Keeps the two panes level as either scrolls. Set once the views are built (`+Layout`).
    var sync: CompareScrollSync?
    var keyMonitor: Any?
    /// Watches for the end of the modal window this one was raised over (`+Modal`).
    let modalLevel = ModalLevelKeeper()
    /// Bumped by every computation, so a slow earlier one cannot land over a newer one.
    var generation = 0
    /// What asks the running read or comparison to stop, or `nil` when none is running.
    var runningStop: CancellationFlag?
    /// How to read the two files, while the sides are still stand-ins (`+Comparing`).
    var reading: CompareReading?
    /// What turns the two sides into what the window shows: the real comparison, or a test's.
    let preparer: Preparer
    /// How long a comparison runs before the toolbar says so. A test lengthens it.
    var comparingDelay = CompareWindowController.usualComparingDelay

    /// Open a window comparing `left` with `right`.
    @discardableResult
    static func present(
        left: CompareSource,
        right: CompareSource,
        allowsCopies: Bool = true,
        saving: CompareSaving
    ) -> CompareWindowController {
        let controller = CompareWindowController(
            left: left,
            right: right,
            allowsCopies: allowsCopies,
            saving: saving
        )
        open.append(controller)
        controller.place()
        controller.raiseAboveModalWindow()
        controller.showWindow(nil)
        controller.compute(options: LineDiffOptions())
        controller.startWatchingFiles()
        return controller
    }

    /// Open a window on two stand-ins and read the files with it on screen (`+Comparing`).
    @discardableResult
    static func presentReading(
        left: CompareSource,
        right: CompareSource,
        allowsCopies: Bool,
        saving: CompareSaving,
        reading: CompareReading
    ) -> CompareWindowController {
        let controller = CompareWindowController(
            left: left,
            right: right,
            allowsCopies: allowsCopies,
            saving: saving,
            reading: reading
        )
        open.append(controller)
        controller.place()
        controller.raiseAboveModalWindow()
        controller.showWindow(nil)
        controller.startReading()
        return controller
    }

    init(
        left: CompareSource,
        right: CompareSource,
        allowsCopies: Bool = true,
        saving: CompareSaving,
        reading: CompareReading? = nil,
        preparer: @escaping Preparer = CompareWindowController.livePreparer
    ) {
        self.left = left
        self.right = right
        self.allowsCopies = allowsCopies
        self.saving = saving
        self.reading = reading
        self.preparer = preparer
        // Not deferred, so a save's sheets attach to a window a test builds and never shows. Probed
        // 2026-10-25: a deferred one took no sheet at all.
        let window = CompareWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 320)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Where the user last left the window, else centered on the browser window: the dialogs'
    /// placement (`DialogWindowPlacement`). The window is resizable, so its size comes back too.
    /// Done in `present` rather than `init`, so a window a test builds saves no frame.
    private func place() {
        guard let window else { return }
        let browser = (NSApp.delegate as? AppDelegate)?.activeBrowserWindowController?.window
        DialogWindowPlacement.place(window, key: "CompareWindow", centeredOver: browser)
    }

    /// One file's line at the top of the panes, or the nearest one above it.
    func topLine(on side: ComparisonPaneText.Side) -> Int? {
        guard let comparison, let top = leftPane.textView.rowAtTop()?.row else { return nil }
        let rows = comparison.rows[...top]
        return switch side {
        case .left: rows.last(where: { $0.left != nil })?.left
        case .right: rows.last(where: { $0.right != nil })?.right
        }
    }

    /// The window's title and each pane's header, for the sides as they stand. A side whose lines
    /// differ from its file is marked in its header, and the close button carries the window's
    /// edited dot while either is.
    func showTitles(edited: (left: Bool, right: Bool) = (false, false)) {
        window?.title = "\(left.name) ↔ \(right.name)"
        leftPane.setTitle(left.name, detail: left.detail, edited: edited.left)
        rightPane.setTitle(right.name, detail: right.detail, edited: edited.right)
        window?.isDocumentEdited = edited.left || edited.right
    }

    // MARK: - Swapping sides

    /// Put the right file on the left and the left file on the right (⌘U).
    ///
    /// The colors read the left side as before and the right as after (`CompareColors`), and the
    /// order a pair opens in is a guess: a marked pair goes older-first, a cursor pair as the panes
    /// stand. This puts a wrong guess right without going back to the panes. The pair is compared
    /// again rather than mirrored, so the window shows what opening it the other way round would,
    /// and the line at the top stays at the top, now in the left pane. Each file takes its copies
    /// with it, and so does its undo, which finds the file by its `id`.
    func swapSides() {
        guard reading == nil else { return NSSound.beep() }
        let keptLine = topLine(on: .right)
        (left, right) = (right, left)
        sidesRevision += 1
        compute(options: toolbar.options, keeping: keptLine.map { KeptLine(side: .left, line: $0) })
    }

    /// Redraw what depends on what is on screen.
    func refreshScrolledViews() {
        band.needsDisplay = true
        overview.visibleRows = leftPane.textView.visibleRows()
        overview.needsDisplay = true
        leftPane.lineNumbers.needsDisplay = true
        rightPane.lineNumbers.needsDisplay = true
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        abandonComparing()
        stopWatchingModalWindow()
        stopWatchingFiles()
        removeKeyMonitor()
        sync?.stop()
        edits.removeAllActions()
        Self.open.removeAll { $0 === self }
    }
}
