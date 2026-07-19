import AppKit
import DirnexCore

/// The workspace organizer sheet (PLAN.md §M3 "Workspaces … named, switchable"): a small
/// editable list of the saved workspaces where the user can drag to reorder, rename in place
/// (double-click), or delete. Presented as a sheet over the browser window via `presentAsSheet`,
/// which retains it for its on-screen lifetime. Every edit is saved to `WorkspaceStore`
/// immediately, so closing — by Done or otherwise — always persists the current order.
///
/// Mirrors `HotlistOrganizerController`; the notable difference is rename, which can be rejected
/// (an empty or already-used name) because a workspace's name is its identity — a rejected edit
/// snaps the field back to the existing name.
@MainActor
final class WorkspaceOrganizerController: NSViewController {
    private var workspaces = WorkspaceStore.load()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let removeButton = NSButton()

    /// Private drag type for internal row reordering.
    private static let rowType = NSPasteboard.PasteboardType("com.dirnex.workspace.row")

    // MARK: - View setup

    override func loadView() {
        let container = EscapeDismissingView()
        container.onEscape = { [weak self] in self?.done(nil) }

        let title = NSTextField(labelWithString: "Organize Workspaces")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        configureButton(removeButton, symbol: "minus", action: #selector(removeSelected(_:)))
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        for subview in [title, scrollView, removeButton, doneButton] {
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            removeButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            removeButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            removeButton.widthAnchor.constraint(equalToConstant: 26),
            removeButton.heightAnchor.constraint(equalToConstant: 24),
            removeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            doneButton.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),

            container.widthAnchor.constraint(equalToConstant: 380),
            container.heightAnchor.constraint(equalToConstant: 360)
        ])

        view = container
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.rowType])
        tableView.doubleAction = #selector(editSelectedName(_:))
        tableView.target = self
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 380, height: 360)
        tableView.reloadData()
        updateRemoveButton()
    }

    // MARK: - Actions

    @objc private func removeSelected(_ sender: Any?) {
        let selected = tableView.selectedRowIndexes
        guard !selected.isEmpty else { return }
        // Remove from the bottom up so earlier indexes stay valid.
        for index in selected.sorted(by: >) {
            workspaces.remove(at: index)
        }
        persist()
        tableView.reloadData()
        updateRemoveButton()
    }

    @objc private func editSelectedName(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard workspaces.workspaces.indices.contains(row) else { return }
        tableView.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func done(_ sender: Any?) {
        dismiss(sender)
    }

    // MARK: - Helpers

    private func persist() {
        WorkspaceStore.save(workspaces)
    }

    private func updateRemoveButton() {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    fileprivate func commitName(_ name: String, forRow row: Int) {
        guard let current = workspace(at: row) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // `rename` rejects an empty name or one already used by another workspace, leaving the
        // list unchanged; the field is then snapped back to the existing name by the caller.
        if workspaces.rename(name: current.name, to: trimmed) {
            persist()
        }
    }

    fileprivate func workspace(at row: Int) -> Workspace? {
        workspaces.workspaces.indices.contains(row) ? workspaces.workspaces[row] : nil
    }

    fileprivate var workspaceCount: Int { workspaces.workspaces.count }

    fileprivate func performReorder(from source: Int, to dropRow: Int) {
        // `NSTableView` reports the drop as an insertion index in pre-removal coordinates;
        // shift it down by one when moving an item further down so it lands where the gap was.
        let destination = dropRow > source ? dropRow - 1 : dropRow
        workspaces.move(from: source, to: destination)
        persist()
        tableView.reloadData()
        if workspaces.workspaces.indices.contains(destination) {
            tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        }
        updateRemoveButton()
    }

    private func configureButton(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
    }
}

// MARK: - NSTableViewDataSource

extension WorkspaceOrganizerController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        workspaceCount
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (
        any NSPasteboardWriting
    )? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        // Identify our own drag by the presence of our private row type on the pasteboard —
        // more reliable than the dragging-source identity across a synthetic drag.
        guard info.draggingPasteboard.availableType(from: [Self.rowType]) != nil else { return [] }
        // Retarget a drop *onto* a row to the gap above it, so releasing anywhere on a row
        // still reorders (the standard `NSTableView` reorder pattern) instead of no-op'ing.
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let string = info.draggingPasteboard.string(forType: Self.rowType),
              let source = Int(string) else { return false }
        performReorder(from: source, to: row)
        return true
    }
}

// MARK: - NSTableViewDelegate

extension WorkspaceOrganizerController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let workspace = workspace(at: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("WorkspaceOrganizerCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        cell.imageView?.image = Self.workspaceIcon
        cell.textField?.stringValue = workspace.name
        cell.textField?.delegate = self
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.imageView = imageView

        let textField = NSTextField()
        textField.isEditable = true
        textField.isBordered = false
        textField.drawsBackground = false
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// A two-pane glyph, matching the switch-menu items so a row reads as a whole-window layout.
    private static let workspaceIcon: NSImage? = {
        let image = NSImage(
            systemSymbolName: "square.split.2x1",
            accessibilityDescription: "Workspace"
        )
        image?.size = NSSize(width: 16, height: 16)
        image?.isTemplate = true
        return image
    }()
}

// MARK: - NSTextFieldDelegate (inline rename)

extension WorkspaceOrganizerController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = tableView.row(for: field)
        guard row >= 0 else { return }
        commitName(field.stringValue, forRow: row)
        // Reflect the stored name back into the field — either the accepted new name, or the
        // original if the rename was rejected (empty or a collision).
        if let workspace = workspace(at: row) { field.stringValue = workspace.name }
    }
}
