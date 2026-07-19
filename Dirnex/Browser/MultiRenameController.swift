import AppKit
import DirnexCore

/// The Multi-Rename Tool sheet (PLAN.md §M4 "Multi-rename tool … live preview table, applies
/// as one undoable batch"). A form of TC's rename controls — name/extension masks, search &
/// replace (literal or regex), case fold, and a counter — over a live preview table that
/// recomputes on every keystroke through the headless `MultiRename` planner. "Rename" hands the
/// applyable proposals back to the panel, which performs the moves and journals them for undo.
///
/// Presented via `presentAsSheet`, which retains it for its on-screen lifetime. All planning is
/// pure `DirnexCore`; this file is the AppKit shell that binds controls to a `RenameSpec` and
/// renders the plan.
@MainActor
final class MultiRenameController: NSViewController {
    private let items: [FileEntry]
    private let existingNames: Set<String>
    /// Handed the clean, applyable proposals when the user commits. The panel performs the
    /// moves and records the undo batch.
    var onApply: (([RenameProposal]) -> Void)?

    private var proposals: [RenameProposal] = []

    // Controls
    private let nameField = NSTextField()
    private let extensionField = NSTextField()
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let regexCheckbox = NSButton(
        checkboxWithTitle: "Regular expression",
        target: nil,
        action: nil
    )
    private let casePopup = NSPopUpButton()
    private let startField = NSTextField()
    private let stepField = NSTextField()
    private let digitsField = NSTextField()

    // Preview + footer
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let renameButton = NSButton()

    /// Case options in popup order, paired with their user-facing titles.
    private let caseOptions: [(title: String, transform: RenameCase)] = [
        ("Original case", .asIs),
        ("lowercase", .lower),
        ("UPPERCASE", .upper),
        ("Capitalized", .capitalized)
    ]

    init(items: [FileEntry], existingNames: Set<String>) {
        self.items = items
        self.existingNames = existingNames
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View setup

    override func loadView() {
        let container = NSView()
        let stack = NSStackView(views: [
            makeControlsGrid(),
            makeLegend(),
            makePreview(),
            makeFooter()
        ])
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
            container.widthAnchor.constraint(equalToConstant: 640),
            container.heightAnchor.constraint(equalToConstant: 540)
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updatePreview()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    private func makeControlsGrid() -> NSView {
        configure(nameField, placeholder: "[N]", string: "[N]", width: 440)
        configure(extensionField, placeholder: "[E]", string: "[E]", width: 440)
        configure(findField, placeholder: "text to find", string: "", width: 440)
        configure(replaceField, placeholder: "replacement", string: "", width: 440)
        regexCheckbox.target = self
        regexCheckbox.action = #selector(controlChanged(_:))
        for (title, _) in caseOptions { casePopup.addItem(withTitle: title) }
        casePopup.target = self
        casePopup.action = #selector(controlChanged(_:))

        let grid = NSGridView(views: [
            [label("Name mask:"), nameField],
            [label("Extension:"), extensionField],
            [label("Search for:"), findField],
            [label("Replace with:"), replaceField],
            [NSGridCell.emptyContentView, regexCheckbox],
            [label("Case:"), casePopup],
            [label("Counter:"), makeCounterRow()]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    private func makeCounterRow() -> NSView {
        configure(startField, placeholder: "1", string: "1", width: 54)
        configure(stepField, placeholder: "1", string: "1", width: 54)
        configure(digitsField, placeholder: "1", string: "1", width: 54)
        let row = NSStackView(views: [
            label("Start"), startField,
            label("Step"), stepField,
            label("Digits"), digitsField
        ])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func makeLegend() -> NSView {
        let text = "Tokens:  [N] name   [E] extension   [C] counter   "
            + "[Y] [M] [D] date   [h] [n] [s] time"
        let legend = NSTextField(labelWithString: text)
        legend.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        legend.textColor = .secondaryLabelColor
        return legend
    }

    private func makePreview() -> NSView {
        for (identifier, title) in [("current", "Current Name"), ("new", "New Name")] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = 280
            tableView.addTableColumn(column)
        }
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.widthAnchor.constraint(equalToConstant: 600).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return scrollView
    }

    private func makeFooter() -> NSView {
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc

        renameButton.title = "Rename"
        renameButton.bezelStyle = .rounded
        renameButton.keyEquivalent = "\r"
        renameButton.target = self
        renameButton.action = #selector(apply(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [statusLabel, spacer, cancelButton, renameButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(equalToConstant: 600).isActive = true
        return footer
    }

    // MARK: - Actions

    @objc private func controlChanged(_ sender: Any?) {
        updatePreview()
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(sender)
    }

    @objc private func apply(_ sender: Any?) {
        let toRename = proposals.filter(\.willRename)
        guard !toRename.isEmpty else { return }
        onApply?(toRename)
        dismiss(sender)
    }

    // MARK: - Preview

    /// Rebuild the plan from the current controls and re-render the table and footer. Runs on
    /// every keystroke (see `controlTextDidChange`) — the planner is pure and cheap.
    private func updatePreview() {
        let spec = currentSpec()
        proposals = MultiRename.plan(for: items, spec: spec, existingNames: existingNames)
        tableView.reloadData()
        updateFooter(spec: spec)
    }

    private func updateFooter(spec: RenameSpec) {
        let renaming = proposals.lazy.filter(\.willRename).count
        let problems = proposals.lazy.filter { $0.status.isProblem }.count

        if !spec.regexIsValid {
            setStatus("Invalid search pattern", isError: true)
            renameButton.isEnabled = false
        } else if problems > 0 {
            setStatus("\(problems) name \(problems == 1 ? "conflict" : "conflicts")", isError: true)
            renameButton.isEnabled = false
        } else {
            setStatus("\(renaming) of \(items.count) will be renamed", isError: false)
            renameButton.isEnabled = renaming > 0
        }
        renameButton.title = renaming > 0 ? "Rename \(renaming) \(renaming == 1 ? "Item" : "Items")"
            : "Rename"
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func currentSpec() -> RenameSpec {
        RenameSpec(
            nameTemplate: nameField.stringValue,
            extensionTemplate: extensionField.stringValue,
            find: findField.stringValue,
            replace: replaceField.stringValue,
            useRegex: regexCheckbox.state == .on,
            caseTransform: caseOptions[max(0, casePopup.indexOfSelectedItem)].transform,
            counter: RenameCounter(
                start: intValue(startField, fallback: 1),
                step: intValue(stepField, fallback: 1),
                padding: max(1, intValue(digitsField, fallback: 1))
            )
        )
    }

    // MARK: - Small helpers

    fileprivate func proposal(at row: Int) -> RenameProposal? {
        proposals.indices.contains(row) ? proposals[row] : nil
    }

    fileprivate var rowCount: Int { proposals.count }

    private func intValue(_ field: NSTextField, fallback: Int) -> Int {
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        return Int(trimmed) ?? fallback
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func configure(_ field: NSTextField, placeholder: String, string: String, width: CGFloat) {
        field.placeholderString = placeholder
        field.stringValue = string
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
}

// MARK: - Preview table data

extension MultiRenameController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
}

extension MultiRenameController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let proposal = proposal(at: row) else { return nil }
        let isNewColumn = column.identifier.rawValue == "new"
        let identifier = NSUserInterfaceItemIdentifier("MultiRenameCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        let field = cell.textField
        field?.stringValue = isNewColumn ? proposal.newName : proposal.originalName
        field?.textColor = isNewColumn ? color(for: proposal.status) : .labelColor
        return cell
    }

    /// New-name colour by disposition: dim for a no-op, red for a blocking problem, normal for
    /// a clean rename — so the user reads the outcome of the whole batch at a glance.
    private func color(for status: RenameStatus) -> NSColor {
        switch status {
        case .unchanged: return .secondaryLabelColor
        case .rename: return .labelColor
        case .emptyName, .invalidCharacter, .duplicate, .collision: return .systemRed
        }
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

// MARK: - Live update as the user types

extension MultiRenameController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updatePreview()
    }
}
