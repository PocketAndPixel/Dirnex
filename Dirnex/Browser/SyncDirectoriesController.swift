import AppKit
import DirnexCore

/// The Synchronize Directories dialog (PLAN.md §M5 "Synchronize directories: two-panel diff view
/// … selective sync actions through the queue"). It compares the two panes' folders through the
/// headless `DirectorySync` engine and lists every difference, one row per item, with a default
/// action derived from the chosen direction. The user picks a direction (mirror either way, or
/// both) and a comparison method (size+date or exact content), un-checks any row to leave it
/// alone, and commits — the panel then runs the checked actions through the M2 queue (copies)
/// and Trash (deletes).
///
/// Presented via `presentAsMovableWindow`, which retains it for its on-screen lifetime. All comparison
/// is pure `DirnexCore`; this file is the AppKit shell that binds the controls to a scan and
/// renders the diff. The scan runs off the main thread (content mode reads bytes).
@MainActor
final class SyncDirectoriesController: NSViewController {
    /// One committed choice handed back to the panel: an entry and the action to perform on it.
    struct Decision {
        let entry: SyncEntry
        let action: SyncAction
    }

    let leftDir: VFSPath
    let rightDir: VFSPath
    let backend: any VFSBackend
    /// The comparison methods honest over this pair of sides, in picker order
    /// (``SyncComparison/available(between:and:)``). Two locations can differ in what their listings
    /// carry, so the control is built from this rather than from a fixed list of three.
    let comparisons: [SyncComparison]
    /// The reconciliations that can actually run here
    /// (``SyncDirection/available(leftAcceptsChanges:rightAcceptsChanges:)``) — a read-only side
    /// loses the directions that would write to it.
    let directions: [SyncDirection]
    /// Handed the checked, actionable decisions when the user commits.
    var onApply: (([Decision]) -> Void)?
    /// Invoked to open two files in an external diff tool (Compare Contents…). The controller is a
    /// pure view; the panel owns process launching and error UI.
    var onCompare: ((VFSPath, VFSPath) -> Void)?

    var direction: SyncDirection
    var comparison: SyncComparison
    var rows: [Row] = []
    var isScanning = false
    var scanError: String?

    /// One diff row: the comparison entry, its current action under the chosen direction, and
    /// whether the user has it checked for the run.
    struct Row {
        let entry: SyncEntry
        var action: SyncAction
        var included: Bool
    }

    // Controls
    let headerLabel = NSTextField(labelWithString: "")
    let directionControl = NSSegmentedControl()
    let comparisonControl = NSSegmentedControl()
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    let spinner = NSProgressIndicator()
    let statusLabel = NSTextField(labelWithString: "")
    let syncButton = NSButton()

    init(
        leftDir: VFSPath,
        rightDir: VFSPath,
        backend: any VFSBackend,
        comparisons: [SyncComparison],
        directions: [SyncDirection]
    ) {
        self.leftDir = leftDir
        self.rightDir = rightDir
        self.backend = backend
        self.comparisons = comparisons
        self.directions = directions
        // The opening choices come from the core's own rules rather than from a constant here, so
        // the segment that is preselected is always one the control actually offers.
        direction = directions.first ?? .leftToRight
        comparison = SyncComparison.default(between: leftDir.backend, and: rightDir.backend)
        super.init(nibName: nil, bundle: nil)
        title = DialogTitle.ofCommand("file.syncDirectories")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View setup

    override func loadView() {
        let container = NSView()
        DialogLayout.fill(
            container,
            with: [makeHeader(), makeControls(), makeTable(), makeFooter()]
        )
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 720),
            container.heightAnchor.constraint(equalToConstant: 520)
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startScan()
    }

    // MARK: - Actions

    @objc func directionChanged(_ sender: NSSegmentedControl) {
        guard directions.indices.contains(sender.selectedSegment) else { return }
        direction = directions[sender.selectedSegment]
        recomputeActions()
    }

    @objc func comparisonChanged(_ sender: NSSegmentedControl) {
        guard comparisons.indices.contains(sender.selectedSegment) else { return }
        comparison = comparisons[sender.selectedSegment]
        startScan()
    }

    /// Re-derive every row's action for the new direction and reset the check state to that
    /// action's default (a direction flip changes what each row *means*, so a fresh default is
    /// less surprising than preserving stale checks).
    private func recomputeActions() {
        rows = rows.map { row in
            let action = DirectorySync.defaultAction(for: row.entry.status, direction: direction)
            return Row(entry: row.entry, action: action, included: isActionable(action))
        }
        tableView.reloadData()
        updateChrome()
    }

    @objc func toggleInclude(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].included = sender.state == .on
        updateChrome()
    }

    /// Override one row's action from its right-click menu — flip a copy the other way, or turn a
    /// copy into a delete. Picking an action opts the row into the run (the checkbox can still skip
    /// it afterward); a direction change later re-derives defaults and drops the override.
    @objc func setRowAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? SyncAction,
              rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].action = action
        rows[sender.tag].included = true
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: sender.tag),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
        updateChrome()
    }

    /// Open the clicked both-sides row's two files in an external diff tool. Only offered when both
    /// sides are regular files (see `menuNeedsUpdate`), so both paths are present.
    @objc func compareContents(_ sender: NSMenuItem) {
        guard let data = row(at: sender.tag),
              let left = data.entry.left?.path,
              let right = data.entry.right?.path else { return }
        onCompare?(left, right)
    }

    @objc func cancel(_ sender: Any?) {
        dismiss(sender)
    }

    @objc func apply(_ sender: Any?) {
        let decisions = rows
            .filter { $0.included && isActionable($0.action) }
            .map { Decision(entry: $0.entry, action: $0.action) }
        guard !decisions.isEmpty else { return }
        onApply?(decisions)
        dismiss(sender)
    }

    // MARK: - Row model access (for the diff-table extension)

    var rowCount: Int { rows.count }

    func row(at index: Int) -> Row? {
        rows.indices.contains(index) ? rows[index] : nil
    }

    // MARK: - Helpers

    func isActionable(_ action: SyncAction) -> Bool {
        action != .none && action != .conflict
    }

    func isCopy(_ action: SyncAction) -> Bool {
        action == .copyToRight || action == .copyToLeft
    }

    /// What to call a side in the header, which since M25 Slice 5c may be on another machine.
    ///
    /// A tilde abbreviation is a fact about *this* home directory, so applying it to a server path
    /// would silently rewrite `/Users/oleg/backup` on a NAS into `~/backup` — a plausible-looking
    /// path naming the wrong place. A remote side is named the way the path bar names it, root
    /// title first.
    func abbreviate(_ path: VFSPath) -> String {
        guard let root = path.backendRootTitle else {
            return (path.path as NSString).abbreviatingWithTildeInPath
        }
        return path.isRoot ? root : "\(root)\(path.path)"
    }

    static func title(for direction: SyncDirection) -> String {
        switch direction {
        case .leftToRight:
            String(
                localized: "Left → Right",
                comment: "Sync direction: mirror the left folder onto the right."
            )
        case .bidirectional:
            String(localized: "Both Directions", comment: "Sync direction: reconcile both folders.")
        case .rightToLeft:
            String(
                localized: "Right → Left",
                comment: "Sync direction: mirror the right folder onto the left."
            )
        }
    }

    static func title(for comparison: SyncComparison) -> String {
        switch comparison {
        case .size:
            // The comment is the file-list column header's, repeated **verbatim**: it is the same
            // key, and two sites commenting one key differently hand the translator whichever
            // `xcstringstool` kept (docs/NOTES.md ▸ Localization). Why size-only is the honest
            // comparison on a server belongs in ``SyncComparison/size``, not in a translator note.
            String(
                localized: "Size",
                comment: "File-list column header: the file's size."
            )
        case .sizeAndDate:
            String(
                localized: "Size & Date",
                comment: "Sync comparison method: compare by size and modification date."
            )
        case .content:
            String(localized: "Content", comment: "Sync comparison method: compare byte-for-byte.")
        }
    }
}
