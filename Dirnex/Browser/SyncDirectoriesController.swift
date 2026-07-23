import AppKit
import DirnexCore

/// The Synchronize Directories sheet (PLAN.md §M5 "Synchronize directories: two-panel diff view
/// … selective sync actions through the queue"). It compares the two panes' folders through the
/// headless `DirectorySync` engine and lists every difference, one row per item, with a default
/// action derived from the chosen direction. The user picks a direction (mirror either way, or
/// both) and a comparison method (size+date or exact content), un-checks any row to leave it
/// alone, and commits — the panel then runs the checked actions through the M2 queue (copies)
/// and Trash (deletes).
///
/// Presented via `presentAsSheet`, which retains it for its on-screen lifetime. All comparison
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
    private let backend: any VFSBackend
    /// Handed the checked, actionable decisions when the user commits.
    var onApply: (([Decision]) -> Void)?
    /// Invoked to open two files in an external diff tool (Compare Contents…). The controller is a
    /// pure view; the panel owns process launching and error UI.
    var onCompare: ((VFSPath, VFSPath) -> Void)?

    private var direction: SyncDirection = .leftToRight
    private var comparison: SyncComparison = .sizeAndDate
    private var rows: [Row] = []
    private var isScanning = false
    private var scanError: String?

    /// One diff row: the comparison entry, its current action under the chosen direction, and
    /// whether the user has it checked for the run.
    struct Row {
        let entry: SyncEntry
        var action: SyncAction
        var included: Bool
    }

    // Controls
    private let headerLabel = NSTextField(labelWithString: "")
    private let directionControl = NSSegmentedControl()
    private let comparisonControl = NSSegmentedControl()
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let syncButton = NSButton()

    init(leftDir: VFSPath, rightDir: VFSPath, backend: any VFSBackend) {
        self.leftDir = leftDir
        self.rightDir = rightDir
        self.backend = backend
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View setup

    override func loadView() {
        let container = NSView()
        let stack = NSStackView(views: [makeHeader(), makeControls(), makeTable(), makeFooter()])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 720),
            container.heightAnchor.constraint(equalToConstant: 520)
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startScan()
    }

    // MARK: - Scan

    /// Run the comparison off the main thread (content mode reads bytes), then rebuild the rows.
    /// Called on load and whenever the comparison method changes; a direction change only
    /// re-derives actions in memory (`recomputeActions`) without re-reading the folders.
    private func startScan() {
        isScanning = true
        scanError = nil
        spinner.startAnimation(nil)
        updateChrome()
        let backend = backend
        let left = leftDir
        let right = rightDir
        let comparison = comparison
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<
                [SyncEntry],
                any Error
            > in
                do {
                    return .success(try DirectorySync.compare(
                        left: left, right: right,
                        leftBackend: backend, rightBackend: backend,
                        comparison: comparison
                    ))
                } catch {
                    return .failure(error)
                }
            }.value
            finishScan(outcome)
        }
    }

    private func finishScan(_ outcome: Result<[SyncEntry], any Error>) {
        isScanning = false
        spinner.stopAnimation(nil)
        switch outcome {
        case let .success(entries):
            rows = entries.map { entry in
                let action = DirectorySync.defaultAction(for: entry.status, direction: direction)
                return Row(entry: entry, action: action, included: isActionable(action))
            }
        case let .failure(error):
            rows = []
            scanError = (error as? VFSError).map(describe) ?? String(
                localized: "The folders couldn’t be compared.",
                comment: "Sync error: the comparison failed for an unspecified reason."
            )
        }
        tableView.reloadData()
        updateChrome()
    }

    // MARK: - Actions

    @objc private func directionChanged(_ sender: NSSegmentedControl) {
        direction = [.leftToRight, .bidirectional, .rightToLeft][max(0, sender.selectedSegment)]
        recomputeActions()
    }

    @objc private func comparisonChanged(_ sender: NSSegmentedControl) {
        comparison = sender.selectedSegment == 1 ? .content : .sizeAndDate
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

    @objc private func cancel(_ sender: Any?) {
        dismiss(sender)
    }

    @objc private func apply(_ sender: Any?) {
        let decisions = rows
            .filter { $0.included && isActionable($0.action) }
            .map { Decision(entry: $0.entry, action: $0.action) }
        guard !decisions.isEmpty else { return }
        onApply?(decisions)
        dismiss(sender)
    }

    // MARK: - Chrome

    private func updateChrome() {
        directionControl.isEnabled = !isScanning
        comparisonControl.isEnabled = !isScanning
        if isScanning {
            setStatus(String(
                localized: "Comparing folders…",
                comment: "Sync status shown while the two folders are being compared."
            ), isError: false)
            syncButton.isEnabled = false
            return
        }
        if let scanError {
            setStatus(scanError, isError: true)
            syncButton.isEnabled = false
            return
        }
        if rows.isEmpty {
            setStatus(String(
                localized: "The folders are already in sync.",
                comment: "Sync status: no differences were found."
            ), isError: false)
            syncButton.isEnabled = false
            return
        }
        let checked = rows.filter { $0.included && isActionable($0.action) }
        let copies = checked.filter { isCopy($0.action) }.count
        let deletes = checked.count - copies
        let conflicts = rows.filter { $0.action == .conflict }.count
        var text = String(
            localized: "\(copies) to copy, \(deletes) to delete",
            comment: "Sync status summary; %1$lld files to copy, %2$lld to delete."
        )
        if conflicts > 0 {
            text += " · " + String(
                localized: "\(conflicts) conflicts skipped",
                comment: "Sync status suffix; %lld conflicting items left unchanged. Plural."
            )
        }
        setStatus(text, isError: false)
        syncButton.isEnabled = !checked.isEmpty
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
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

    private func isCopy(_ action: SyncAction) -> Bool {
        action == .copyToRight || action == .copyToLeft
    }

    private func abbreviate(_ path: VFSPath) -> String {
        (path.path as NSString).abbreviatingWithTildeInPath
    }

    private func describe(_ error: VFSError) -> String {
        switch error {
        case .notFound:
            return String(
                localized: "One of the folders no longer exists.",
                comment: "Sync error: a compared folder was removed."
            )
        case .permissionDenied:
            return String(
                localized: "Permission was denied reading one of the folders.",
                comment: "Sync error: no read permission on a compared folder."
            )
        default:
            return String(
                localized: "The folders couldn’t be compared.",
                comment: "Sync error: the comparison failed for an unspecified reason."
            )
        }
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func spacer(width: CGFloat) -> NSView {
        let view = NSView()
        if width > 0 {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        } else {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return view
    }
}

// MARK: - View construction

private extension SyncDirectoriesController {
    func makeHeader() -> NSView {
        headerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.stringValue = "\(abbreviate(leftDir))   ⟷   \(abbreviate(rightDir))"
        headerLabel.widthAnchor.constraint(equalToConstant: 680).isActive = true
        return headerLabel
    }

    func makeControls() -> NSView {
        let directions = [
            String(
                localized: "Left → Right",
                comment: "Sync direction: mirror the left folder onto the right."
            ),
            String(localized: "Both Directions", comment: "Sync direction: reconcile both folders."),
            String(
                localized: "Right → Left",
                comment: "Sync direction: mirror the right folder onto the left."
            )
        ]
        for (index, title) in directions.enumerated() {
            directionControl.segmentCount = 3
            directionControl.setLabel(title, forSegment: index)
        }
        directionControl.selectedSegment = 0
        directionControl.target = self
        directionControl.action = #selector(directionChanged(_:))

        let comparisons = [
            String(
                localized: "Size & Date",
                comment: "Sync comparison method: compare by size and modification date."
            ),
            String(localized: "Content", comment: "Sync comparison method: compare byte-for-byte.")
        ]
        for (index, title) in comparisons.enumerated() {
            comparisonControl.segmentCount = 2
            comparisonControl.setLabel(title, forSegment: index)
        }
        comparisonControl.selectedSegment = 0
        comparisonControl.target = self
        comparisonControl.action = #selector(comparisonChanged(_:))

        let hint = label(String(
            localized: "Right-click a row to change its action",
            comment: "Sync sheet hint above the diff table."
        ))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        // The hint is the one element that yields: a longer translation of the controls (Russian's
        // are far wider than English's) must truncate the hint away rather than collapse the
        // direction control to an unreadable "…". The controls keep the stock 750 resistance.
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [
            label(
                String(
                    localized: "Direction:",
                    comment: "Sync sheet label before the direction control."
                )
            ),
            directionControl,
            spacer(width: 16),
            label(
                String(
                    localized: "Compare by:",
                    comment: "Sync sheet label before the comparison-method control."
                )
            ),
            comparisonControl,
            spacer(width: 0), hint
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 680).isActive = true
        return row
    }

    func makeTable() -> NSView {
        addColumn("include", title: "", width: 26)
        addColumn(
            "name",
            title: String(
                localized: "Item",
                comment: "Sync diff table column header: the item's relative path."
            ),
            width: 300
        )
        addColumn("left", title: leftDir.lastComponent, width: 130)
        addColumn("action", title: "", width: 60)
        addColumn("right", title: rightDir.lastComponent, width: 130)
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.dataSource = self
        tableView.delegate = self

        // Right-click a row to override its action (rebuilt per-click from the clicked row).
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: 680).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
        return scrollView
    }

    func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    func makeFooter() -> NSView {
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let cancelButton = NSButton(
            title: String(localized: "Cancel", comment: "Dismiss button."),
            target: self,
            action: #selector(cancel(_:))
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc

        syncButton.title = String(
            localized: "Synchronize",
            comment: "Confirm button of the sync delete prompt and the sync sheet."
        )
        syncButton.bezelStyle = .rounded
        syncButton.keyEquivalent = "\r"
        syncButton.target = self
        syncButton.action = #selector(apply(_:))

        let footer = NSStackView(views: [statusLabel, spacer(width: 0), cancelButton, syncButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(equalToConstant: 680).isActive = true
        return footer
    }
}
