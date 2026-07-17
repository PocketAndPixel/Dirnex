import AppKit
import DirnexCore

/// The Cmd+K command palette (PLAN.md §M3): a floating search field over a fuzzy-ranked list
/// of every registry command, with recents on top and each command's shortcut shown. Picking
/// one dismisses the palette and sends the command's selector through the responder chain —
/// so it lands on the focused pane / key window exactly as the menu item would.
///
/// The panel is built fresh on each open and torn down on dismiss; a palette open/close is
/// rare enough that reuse buys nothing and a fresh field starts empty every time. The search
/// field stays first responder and drives the list selection from `control(_:doCommandBy:)`
/// (↑/↓ move, ⏎ runs, ⎋ closes), so the list needs no key handling of its own.
@MainActor
final class CommandPaletteController: NSObject {
    private var panel: NSPanel?
    let searchField = NSTextField()
    let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /// The current ranked results the list renders. Rebuilt on every keystroke.
    var matches: [CommandMatch] = []
    /// The highlighted row, kept in step with `tableView.selectedRow`.
    var selectedIndex = 0

    private let recents = CommandRecents()
    /// Resolves each command's effective (possibly rebound) shortcut so the palette shows the
    /// same glyph the menu does. Read live on each open, so a rebind is reflected next time.
    let keyBindings = KeyBindingStore.shared
    /// The window the palette floats over and re-keys on dismiss, so the dispatched command
    /// runs against that window's focused pane rather than the palette.
    private weak var targetWindow: NSWindow?

    private static let panelWidth: CGFloat = 620
    private static let panelHeight: CGFloat = 420
    private static let fieldHeight: CGFloat = 52

    /// Open the palette over `window`, or close it if it is already showing (⌘K toggles).
    func toggle(over window: NSWindow?) {
        if panel != nil {
            dismiss()
        } else {
            show(over: window)
        }
    }

    private func show(over window: NSWindow?) {
        targetWindow = window
        let panel = makePanel()
        self.panel = panel
        // The search field is reused across opens, so clear last time's query before
        // ranking — otherwise the field shows stale text while the list resets to recents.
        searchField.stringValue = ""
        reload(query: "")
        position(panel, over: window)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    /// Tear down the palette and hand key focus back to the browser window. Clearing the
    /// delegate first stops the resign-key handler from re-entering this method.
    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
        targetWindow?.makeKeyAndOrderFront(nil)
    }

    /// Run the highlighted command: record it as recent, dismiss, then dispatch its selector
    /// on the next runloop tick — after `dismiss()` has re-keyed the browser window, so the
    /// responder chain reaches the focused pane and not the (now closed) palette.
    func runSelected() {
        guard matches.indices.contains(selectedIndex) else { return }
        let id = matches[selectedIndex].command.id
        recents.record(id)
        dismiss()
        // A user script has no static selector — route it to the focused pane's `runUserScript`,
        // carrying the script name in a synthetic sender's `representedObject` (the same shape the
        // right-click Scripts ▸ items use). Dispatch on the next tick, after `dismiss()` re-keys the
        // browser window, so the action reaches the pane and not the closing palette.
        if let name = UserScript.name(fromCommandID: id) {
            DispatchQueue.main.async {
                let sender = NSMenuItem()
                sender.representedObject = name
                NSApp.sendAction(
                    #selector(PanelViewController.runUserScript(_:)),
                    to: nil,
                    from: sender
                )
            }
            return
        }
        guard let selector = CommandBinding.selector(for: id) else { return }
        DispatchQueue.main.async {
            NSApp.sendAction(selector, to: nil, from: nil)
        }
    }

    // MARK: - Results

    /// Re-rank against `query` and refresh the list, landing the highlight on the top result.
    /// The registry commands are joined with the user's saved scripts (read fresh each open, so a
    /// script created in the organizer is searchable immediately) — they rank and render alongside
    /// the built-ins, and `runSelected` routes a `userScript.*` pick to the script runner.
    func reload(query: String) {
        let commands = CommandCatalog.all + UserScriptStore.load().paletteCommands
        matches = CommandMatcher.search(query, in: commands, recents: recents.ids)
        selectedIndex = matches.isEmpty ? -1 : 0
        tableView.reloadData()
        if selectedIndex >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// Move the highlight by `delta` rows, clamped to the result list.
    func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let target = min(max(selectedIndex + delta, 0), matches.count - 1)
        guard target != selectedIndex else { return }
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        tableView.scrollRowToVisible(target)
    }

    /// The shortcut to print beside `command` in its row.
    ///
    /// `KeyBindings` models the *registry* only: it resolves an id with no override by looking it up
    /// in `CommandCatalog`, so asking it about a command that isn't in the catalog — a user script,
    /// whose F-key binding lives on the script itself — always answers `nil`, and the key would go
    /// unadvertised. Those commands carry their own shortcut, and it is authoritative.
    ///
    /// The catalog check is what keeps this narrow: a *catalog* command must still go through the
    /// bindings, because `nil` there can mean the user deliberately unbound it, and falling back to
    /// `Command.shortcut` would print the default they just removed.
    func shortcut(for command: Command) -> CommandShortcut? {
        guard CommandCatalog.command(for: command.id) != nil else { return command.shortcut }
        return keyBindings.shortcut(for: command.id)
    }

    // MARK: - Building

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = true
        panel.delegate = self
        panel.contentView = makeContentView()
        return panel
    }

    private func makeContentView() -> NSView {
        searchField.placeholderString = "Run a command…"
        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.usesSingleLineMode = true
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        [searchField, divider, scrollView].forEach(container.addSubview)

        // The field sizes to its own text height and is centered within a fixed `fieldHeight`
        // band (the divider caps the band). Centering the field itself — rather than stretching
        // it to the full band — keeps both the placeholder and the caret on the band's midline.
        NSLayoutConstraint.activate([
            searchField.centerYAnchor.constraint(
                equalTo: container.topAnchor,
                constant: Self.fieldHeight / 2
            ),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            divider.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.fieldHeight),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        return container
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.rowHeight = 40
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
    }

    @objc private func rowDoubleClicked() {
        runSelected()
    }

    /// Center the palette horizontally over `window` and sit it in the upper third, the
    /// familiar Spotlight/Alfred position. Falls back to the main screen when detached.
    private func position(_ panel: NSPanel, over window: NSWindow?) {
        let reference = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let originX = reference.midX - Self.panelWidth / 2
        let originY = reference.midY + reference.height / 6
        panel.setFrameOrigin(NSPoint(x: originX.rounded(), y: originY.rounded()))
    }
}
