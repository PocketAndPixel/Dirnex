import AppKit
import DirnexCore

/// One of the three versions a merge is made from, as its entry point names it.
struct MergeVersion: Sendable {
    /// Where this version comes from, under its pane's title.
    let detail: String
    let document: ComparedDocument
}

/// What a merge window is opened on (PLAN.md §M34 Slice 3). A server file changed under an F4 edit
/// (Slice 4) and a conflicted git row (Slice 5) each build one.
struct MergeInput: Sendable {
    /// The file being merged, which names the window and its questions.
    let name: String
    let base: MergeVersion
    let yours: MergeVersion
    let theirs: MergeVersion
    /// The local file Save writes the result into, as it was when the versions were read: the
    /// editor's copy of a server file, or a conflicted file's working-tree copy.
    let target: ComparedFileSave.Target
    /// Where the result goes, under the Result pane's title.
    let resultDetail: String
    /// The grammar the panes are colored by, or `nil` for none.
    let language: SyntaxLanguage?
}

/// What the merge window's save needs besides the file: the undo store, and whose journal records
/// the save, as `CompareSaving` carries them for the compare window. Handed in with no default, so a
/// window a test builds files nothing into the developer's own store or journal.
struct MergeSaving {
    let undo: @MainActor () -> ArchiveUndoStorage.Request
    let journal: @MainActor (UndoRecord) -> Void
    /// Carries the result on once it is in the file, asking over the window given: the server
    /// entry's upload (PLAN.md §M34 Slice 4). `nil` where a save ends at the file, as a working-tree
    /// file's does. The save counts as done before it runs, since the file it carries is the
    /// editor's watched copy, whose next save is carried as F4's is.
    var carry: (@MainActor (NSWindow?) async -> Void)?
    /// Called once the window has closed.
    var closed: @MainActor () -> Void = {}

    /// For a window whose saves keep no undo: a test's.
    static var none: MergeSaving {
        MergeSaving(undo: { .none }, journal: { _ in })
    }
}

/// Dirnex's merge window (PLAN.md §M34 Slice 3): three versions of one file level row for row,
/// Yours, Result and Theirs, with the base they started from shown on request at the left edge.
///
/// What the merge *is* lives in the core (`TextMerge`): a region only one side changed is in the
/// result from the start, and each conflict waits for a choice, Yours, Theirs or Both in either order
/// (`+Conflicts`). Every choice is undone through the window's own undo manager. The result is
/// written only once every conflict has one (`+Save`), so no conflict marker is ever written.
///
/// The panes are the compare window's, kept level by the same `CompareScrollSync`, and everything
/// they show is prepared off the main thread after each choice (`MergePrepared`).
@MainActor
final class MergeWindowController: NSWindowController, NSWindowDelegate {
    /// Windows on screen. A controller holds itself here until its window closes.
    private(set) static var open: [MergeWindowController] = []

    let input: MergeInput
    let saving: MergeSaving
    /// The merge as it stands, `nil` until it has been computed.
    var merge: TextMerge?
    /// The file Save writes, as it was read or last saved: the witness the next save is checked
    /// against.
    var target: ComparedFileSave.Target
    /// The choices the file holds, `nil` until the result has been saved.
    var savedChoices: [TextMerge.Choice?]?
    /// Whether a save is running.
    var isSaving = false {
        didSet { refreshControls() }
    }

    /// The conflict the band marks, the counter names and a take acts on, or `nil` for none.
    var currentConflict: Int?
    /// The window's undo: Edit ▸ Undo reaches it through `NSWindow`, which asks the delegate for it.
    /// Each choice groups itself, so it does not group by event.
    let edits: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    /// What is on screen, and how many choices it has seen: `choicesMade` counts every choice and
    /// undo, and `shownChoices` is the count the screen was prepared from.
    private(set) var shown: MergePrepared?
    var choicesMade = 0
    private(set) var shownChoices = 0

    let toolbar = MergeToolbar()
    let banner = NSTextField(wrappingLabelWithString: "")
    let basePane = ComparePaneView(side: nil)
    let yoursPane = ComparePaneView(side: nil)
    let resultPane = ComparePaneView(side: nil)
    let theirsPane = ComparePaneView(side: nil)
    /// The strips between the panes, each marking the same regions.
    let baseBand = CompareBandView()
    let yoursBand = CompareBandView()
    let theirsBand = CompareBandView()
    let overview = CompareOverviewView()
    /// Where Yours starts: after the base while it is shown, else at the window's edge (`+Layout`).
    var yoursAfterBase: NSLayoutConstraint?
    var yoursAtEdge: NSLayoutConstraint?
    var sync: CompareScrollSync?
    var keyMonitor: Any?
    /// Bumped by every preparation, so a slow earlier one cannot land over a newer one.
    private var generation = 0

    /// Each column's pane.
    var panes: [(column: MergeRow.Column, pane: ComparePaneView)] {
        [(.base, basePane), (.yours, yoursPane), (.result, resultPane), (.theirs, theirsPane)]
    }

    var bands: [CompareBandView] {
        [baseBand, yoursBand, theirsBand]
    }

    /// Open a window merging `input`'s versions.
    @discardableResult
    static func present(_ input: MergeInput, saving: MergeSaving) -> MergeWindowController {
        let controller = MergeWindowController(input: input, saving: saving)
        open.append(controller)
        controller.place()
        controller.showWindow(nil)
        controller.start()
        return controller
    }

    init(input: MergeInput, saving: MergeSaving) {
        self.input = input
        self.saving = saving
        target = input.target
        // Not deferred, so a save's sheets attach to a window a test builds and never shows
        // (docs/NOTES.md ▸ Testing).
        let window = CompareWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 360)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Where the user last left the window, else centered on the browser window.
    private func place() {
        guard let window else { return }
        let browser = (NSApp.delegate as? AppDelegate)?.activeBrowserWindowController?.window
        DialogWindowPlacement.place(window, key: "MergeWindow", centeredOver: browser)
    }

    // MARK: - Computing

    /// Merge the three versions off the main thread, then show the merge.
    private func start() {
        let input = input
        Task { [weak self] in
            let merge = await BlockingWork.run {
                TextMerge(
                    base: input.base.document,
                    yours: input.yours.document,
                    theirs: input.theirs.document
                )
            }
            self?.load(merge)
        }
    }

    /// Show `merge` as it opens, with its first conflict current. `prepared` shows it at once, for
    /// a test; without it, it is prepared off the main thread.
    func load(_ merge: TextMerge, prepared: MergePrepared? = nil) {
        self.merge = merge
        currentConflict = merge.choices.isEmpty ? nil : 0
        if let prepared {
            show(prepared, revealing: currentConflict)
        } else {
            prepare(revealing: currentConflict)
        }
    }

    /// Prepare the merge as it stands for the screen, then show it with `conflict` revealed.
    func prepare(revealing conflict: Int?) {
        guard let merge else { return }
        generation += 1
        let generation = generation
        let choices = choicesMade
        let language = input.language
        let limit = CompareTextStyle.syntaxColoringLimit
        Task { [weak self] in
            let prepared = await BlockingWork.run {
                MergePrepared.prepare(merge, language: language, coloringLimit: limit)
            }
            guard let self, generation == self.generation else { return }
            shownChoices = choices
            show(prepared, revealing: conflict)
        }
    }

    /// Put a prepared merge on screen, and reveal `conflict` if it is one.
    func show(_ prepared: MergePrepared, revealing conflict: Int?) {
        shown = prepared
        for (column, pane) in panes {
            guard let text = prepared.panes[column] else { continue }
            pane.show(
                text.text,
                document: CompareTextStyle.document(for: text.text, rows: [], tokens: text.tokens),
                fills: text.fills,
                lineCount: text.lineCount
            )
        }
        for band in bands {
            band.changeRows = prepared.markRows
            band.kinds = prepared.markKinds
        }
        overview.rowCount = prepared.rowCount
        overview.changeRows = prepared.markRows
        overview.kinds = prepared.markKinds
        banner.stringValue = Self.bannerText(
            conflicts: prepared.conflictCount,
            open: prepared.openConflictCount
        ) ?? ""
        banner.isHidden = banner.stringValue.isEmpty
        window?.contentView?.layoutSubtreeIfNeeded()
        refreshControls()
        if let conflict, prepared.conflictRows.indices.contains(conflict) {
            sync?.reveal(row: prepared.conflictRows[conflict].lowerBound)
        }
        refreshScrolledViews()
    }

    /// The window's title, the panes' headers, the controls, and the edited dot, as the merge
    /// stands.
    func refreshControls() {
        window?.title = String(
            localized: "Merge of “\(input.name)”",
            comment: "Merge window title; %@ is the name of the file being merged."
        )
        basePane.setTitle(Self.columnTitle(.base), detail: input.base.detail)
        yoursPane.setTitle(Self.columnTitle(.yours), detail: input.yours.detail)
        resultPane.setTitle(Self.columnTitle(.result), detail: input.resultDetail)
        theirsPane.setTitle(Self.columnTitle(.theirs), detail: input.theirs.detail)
        let count = merge?.choices.count
        let current = currentConflict.flatMap { (count ?? 0) > $0 ? $0 : nil }
        toolbar.showCounter(current: current, count: count)
        let mark = current.flatMap { conflict in
            shown.flatMap { $0.conflictMarks.indices.contains(conflict) ? $0.conflictMarks[conflict] : nil }
        }
        for band in bands {
            band.current = mark
            band.needsDisplay = true
        }
        toolbar.save.isEnabled = canSave
        window?.isDocumentEdited = hasUnsavedChoices
    }

    /// Redraw what depends on what is on screen.
    func refreshScrolledViews() {
        for band in bands where !band.isHidden {
            band.needsDisplay = true
        }
        overview.visibleRows = yoursPane.textView.visibleRows()
        overview.needsDisplay = true
        for (_, pane) in panes where !pane.isHidden {
            pane.lineNumbers.needsDisplay = true
        }
    }

    // MARK: - Words

    /// Each column's pane title.
    static func columnTitle(_ column: MergeRow.Column) -> String {
        switch column {
        case .yours:
            String(localized: "Yours", comment: "Merge window pane title: your version of the file.")
        case .result:
            String(
                localized: "Result",
                comment: "Merge window pane title: the merged file being built."
            )
        case .theirs:
            String(
                localized: "Theirs",
                comment: "Merge window pane title: the other version of the file, merged into yours."
            )
        case .base:
            String(
                localized: "Base",
                comment: "Merge window pane title: the version both sides started from."
            )
        }
    }

    /// The line under the toolbar: that a merge had no conflict at all, or how many are still
    /// open and that Save waits for them. Nothing once every conflict has a choice.
    static func bannerText(conflicts: Int, open: Int) -> String? {
        if conflicts == 0 {
            return String(
                localized: "Every change merged without a conflict.",
                comment: "Merge window: both sides' changes merged on their own, and nothing waits for a choice."
            )
        }
        guard open > 0 else { return nil }
        return String(
            localized: "\(open) conflicts are still open. The result can be saved once each has a choice.",
            comment: "Merge window: why Save is unavailable; %lld is how many conflicts have no choice yet."
        )
    }

    // MARK: - Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        edits
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        sync?.stop()
        edits.removeAllActions()
        Self.open.removeAll { $0 === self }
        saving.closed()
    }
}
