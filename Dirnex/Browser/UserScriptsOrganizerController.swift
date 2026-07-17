import AppKit
import DirnexCore

/// The scripts organizer sheet (PLAN.md §M6 "user actions — shell scripts … surfaced in palette
/// and F-key bar") — where the user *creates* the scripts the palette and the right-click
/// **Scripts ▸** submenu then run. A master–detail sheet: the saved scripts on the left, an editor
/// for the selected one on the right (name, run mode, palette keywords, and the shell body).
///
/// Presented over the browser window via `presentAsSheet`, which retains it. Every edit is written
/// straight to `UserScriptStore` (which posts its change notification, so an open palette picks the
/// change up on its next open), so closing — by Done or Escape — always persists the current state,
/// exactly like the hotlist / saved-search organizers.
@MainActor
final class UserScriptsOrganizerController: NSViewController {
    private var scripts = UserScriptStore.load()
    /// The name (identity) of the script currently loaded into the editor, so a commit targets the
    /// right script even if the table selection is mid-change. `nil` when nothing is selected.
    private var editingName: String?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let removeButton = NSButton()

    private let nameField = NSTextField()
    private let runModePopUp = NSPopUpButton()
    private let functionKeyPopUp = NSPopUpButton()
    private let keywordsField = NSTextField()
    private let commandTextView = NSTextView()
    private let commandScrollView = NSScrollView()
    private let detailStack = NSStackView()

    // MARK: - View setup

    override func loadView() {
        let container = EscapeDismissingView()
        container.onEscape = { [weak self] in self?.done(nil) }
        // This sheet is a form, not a list with a transient rename: a field holds focus almost
        // always, so Escape has to close over the field editor or it would never close at all.
        // `done` flushes the in-progress edit first, so nothing typed is lost on the way out.
        container.dismissesWhileEditing = true

        let title = NSTextField(labelWithString: "Scripts")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        configureButton(addButton, symbol: "plus", action: #selector(addScript(_:)))
        configureButton(removeButton, symbol: "minus", action: #selector(removeSelected(_:)))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        configureDetail()

        let doneButton = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        for subview in [title, scrollView, addButton, removeButton, detailStack, doneButton] {
            container.addSubview(subview)
        }
        activateConstraints(in: container, title: title, doneButton: doneButton)
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 640, height: 460)
        tableView.reloadData()
        selectRow(scripts.scripts.isEmpty ? nil : 0)
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
    }

    /// The right-hand editor: a vertical stack of labeled controls, the command body filling the
    /// slack so a long script gets room. Built once; its values are swapped in on each selection.
    private func configureDetail() {
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.delegate = self
        nameField.placeholderString = "Script name"

        runModePopUp.translatesAutoresizingMaskIntoConstraints = false
        runModePopUp.addItem(withTitle: "Run once for the whole selection")
        runModePopUp.lastItem?.representedObject = UserScriptRunMode.combined
        runModePopUp.addItem(withTitle: "Run once per selected file")
        runModePopUp.lastItem?.representedObject = UserScriptRunMode.perFile
        runModePopUp.target = self
        runModePopUp.action = #selector(runModeChanged(_:))

        functionKeyPopUp.translatesAutoresizingMaskIntoConstraints = false
        functionKeyPopUp.target = self
        functionKeyPopUp.action = #selector(functionKeyChanged(_:))

        keywordsField.translatesAutoresizingMaskIntoConstraints = false
        keywordsField.delegate = self
        keywordsField.placeholderString = "Palette keywords (comma-separated)"

        configureCommandView()

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 6
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.addArrangedSubview(fieldLabel("Name"))
        detailStack.addArrangedSubview(nameField)
        detailStack.addArrangedSubview(fieldLabel("When run"))
        detailStack.addArrangedSubview(runModePopUp)
        detailStack.addArrangedSubview(fieldLabel("Function key"))
        detailStack.addArrangedSubview(functionKeyPopUp)
        detailStack.addArrangedSubview(fieldLabel("Keywords"))
        detailStack.addArrangedSubview(keywordsField)
        detailStack.addArrangedSubview(fieldLabel("Command"))
        detailStack.addArrangedSubview(commandScrollView)
        detailStack.addArrangedSubview(helpLabel())
        for control in [nameField, runModePopUp, functionKeyPopUp, keywordsField, commandScrollView] {
            control.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        }
        commandScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        commandScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func configureCommandView() {
        commandTextView.isRichText = false
        commandTextView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        commandTextView.isAutomaticQuoteSubstitutionEnabled = false
        commandTextView.isAutomaticDashSubstitutionEnabled = false
        commandTextView.isAutomaticSpellingCorrectionEnabled = false
        commandTextView.delegate = self
        commandTextView.allowsUndo = true
        commandTextView.isVerticallyResizable = true
        commandTextView.textContainer?.widthTracksTextView = true

        commandScrollView.documentView = commandTextView
        commandScrollView.hasVerticalScroller = true
        commandScrollView.borderType = .bezelBorder
        commandScrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func activateConstraints(
        in container: NSView,
        title: NSTextField,
        doneButton: NSButton
    ) {
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.widthAnchor.constraint(equalToConstant: 190),

            addButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            addButton.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 26),
            addButton.heightAnchor.constraint(equalToConstant: 24),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 6),
            removeButton.widthAnchor.constraint(equalToConstant: 26),
            removeButton.heightAnchor.constraint(equalToConstant: 24),

            detailStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            detailStack.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 16),
            detailStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            detailStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            doneButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),

            container.widthAnchor.constraint(equalToConstant: 640),
            container.heightAnchor.constraint(equalToConstant: 460)
        ])
    }

    // MARK: - Actions

    @objc private func addScript(_ sender: Any?) {
        let name = uniqueName(base: "New Script")
        scripts.save(UserScript(name: name, command: "", runMode: .combined))
        persist()
        tableView.reloadData()
        if let index = scripts.scripts.firstIndex(where: { $0.name == name }) {
            selectRow(index)
            view.window?.makeFirstResponder(nameField)
            nameField.selectText(nil)
        }
    }

    @objc private func removeSelected(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        scripts.remove(at: index)
        persist()
        tableView.reloadData()
        let next = min(index, scripts.scripts.count - 1)
        selectRow(scripts.scripts.isEmpty ? nil : next)
    }

    @objc private func runModeChanged(_ sender: Any?) {
        guard let name = editingName, var script = scripts.script(named: name),
              let mode = runModePopUp.selectedItem?.representedObject as? UserScriptRunMode else {
            return
        }
        script.runMode = mode
        scripts.save(script)
        persist()
    }

    /// Commit the function-key popup. `save` steals the key from any script already holding it, so
    /// the newest assignment wins; the bar rebuilds off the store's change notification.
    @objc private func functionKeyChanged(_ sender: Any?) {
        guard let name = editingName, var script = scripts.script(named: name) else { return }
        script.functionKey = functionKeyPopUp.selectedItem?.representedObject as? Int
        scripts.save(script)
        persist()
        // A steal silently unbound another script — reload so its popup is right when selected.
        loadFunctionKeys(selecting: script.functionKey)
    }

    @objc private func done(_ sender: Any?) {
        // Flush any in-progress field edit (Done can be clicked while a field still has focus).
        view.window?.makeFirstResponder(nil)
        dismiss(sender)
    }

    // MARK: - Commit

    /// Commit the name field: rename the edited script, or revert the field when the new name is
    /// empty or already taken (name is identity — two scripts can't share one).
    fileprivate func commitName() {
        guard let old = editingName else { return }
        let new = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard new != old else { return }
        if scripts.rename(name: old, to: new) {
            editingName = new
            persist()
            tableView.reloadData()
            if let index = scripts.scripts.firstIndex(where: { $0.name == new }) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        } else {
            // Rejected (empty or a clash): restore the field to the real name, keep the script.
            nameField.stringValue = old
            NSSound.beep()
        }
    }

    /// Commit the command / keywords (name and run mode are committed on their own events).
    fileprivate func commitBody() {
        guard let name = editingName, var script = scripts.script(named: name) else { return }
        script.command = commandTextView.string
        script.keywords = parseKeywords(keywordsField.stringValue)
        scripts.save(script)
        persist()
    }

    // MARK: - Selection

    private var selectedIndex: Int? {
        tableView.selectedRow >= 0 ? tableView.selectedRow : nil
    }

    private func selectRow(_ index: Int?) {
        if let index, scripts.scripts.indices.contains(index) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        loadDetail()
    }

    /// Load the selected script into the editor, or clear and disable it when nothing is selected.
    fileprivate func loadDetail() {
        guard let index = selectedIndex, scripts.scripts.indices.contains(index) else {
            editingName = nil
            setDetailEnabled(false)
            nameField.stringValue = ""
            keywordsField.stringValue = ""
            commandTextView.string = ""
            loadFunctionKeys(selecting: nil)
            removeButton.isEnabled = false
            return
        }
        let script = scripts.scripts[index]
        editingName = script.name
        setDetailEnabled(true)
        nameField.stringValue = script.name
        keywordsField.stringValue = script.keywords.joined(separator: ", ")
        commandTextView.string = script.command
        selectRunMode(script.runMode)
        loadFunctionKeys(selecting: script.functionKey)
        removeButton.isEnabled = true
    }
}

// MARK: - Helpers
//
// In a `private extension` (which SwiftLint's `type_body_length` doesn't count against the class):
// same-file extensions share the type's `private` scope, so these still reach its stored controls.

private extension UserScriptsOrganizerController {
    func persist() {
        UserScriptStore.save(scripts)
    }

    func setDetailEnabled(_ enabled: Bool) {
        nameField.isEnabled = enabled
        runModePopUp.isEnabled = enabled
        functionKeyPopUp.isEnabled = enabled
        keywordsField.isEnabled = enabled
        commandTextView.isEditable = enabled
        commandTextView.isSelectable = enabled
    }

    func selectRunMode(_ mode: UserScriptRunMode) {
        let index = runModePopUp.itemArray.firstIndex {
            $0.representedObject as? UserScriptRunMode == mode
        }
        if let index { runModePopUp.selectItem(at: index) }
    }

    /// Rebuild the function-key popup and select `key`.
    ///
    /// Only keys nothing else claims are offered: a key carrying a menu equivalent is dispatched by
    /// AppKit *before* the pane's key handler runs, so a script bound to one would run from its bar
    /// button and do nothing from the key itself — offering it would be offering a broken binding.
    /// The list is derived from the user's live shortcut bindings, so rebinding a command frees or
    /// claims a key here too.
    ///
    /// A script already holding a key that has *since* become reserved keeps it, shown as
    /// unavailable rather than silently reading "None" — the popup would otherwise both lie about
    /// the script and discard the binding on the next edit.
    func loadFunctionKeys(selecting key: Int?) {
        let assignable = FunctionBar.assignableFunctionKeys(
            bindings: KeyBindingStore.shared.bindings
        )
        functionKeyPopUp.removeAllItems()
        functionKeyPopUp.addItem(withTitle: "None")
        functionKeyPopUp.lastItem?.representedObject = nil
        for number in assignable {
            functionKeyPopUp.addItem(withTitle: "F\(number)")
            functionKeyPopUp.lastItem?.representedObject = number
        }
        if let key, !assignable.contains(key) {
            functionKeyPopUp.addItem(withTitle: "F\(key) (unavailable)")
            functionKeyPopUp.lastItem?.representedObject = key
        }
        let index = functionKeyPopUp.itemArray.firstIndex { $0.representedObject as? Int == key }
        functionKeyPopUp.selectItem(at: index ?? 0)
    }

    func parseKeywords(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A name not already in use, e.g. "New Script", then "New Script 2", "New Script 3"…
    func uniqueName(base: String) -> String {
        guard scripts.contains(name: base) else { return base }
        var suffix = 2
        while scripts.contains(name: "\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    func helpLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString:
            "The selection is passed as arguments (\"$@\", \"$1\"). "
                + "Also available: $DIRNEX_CURRENT_DIR, $DIRNEX_OTHER_DIR, $DIRNEX_SELECTED_PATHS.")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    func configureButton(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension UserScriptsOrganizerController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        scripts.scripts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard scripts.scripts.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("UserScriptCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = scripts.scripts[row].name
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        loadDetail()
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

// MARK: - Editing commits

extension UserScriptsOrganizerController: NSTextFieldDelegate, NSTextViewDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === nameField {
            commitName()
        } else if field === keywordsField {
            commitBody()
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === commandTextView else { return }
        commitBody()
    }
}
