import AppKit

/// Holding ⌘ floats the full name of the cursor row when the Name column cuts it short: the panel a
/// hover floats (`ExpandingLabel`), reached from the keyboard. A file manager driven from the keys
/// otherwise had no way to read a truncated name without the mouse or a wider column.
///
/// **It waits ``TabShortcuts/revealDelay`` before appearing**, the same hold that shows a dialog's tab
/// numbers, so a quick ⌘C or ⌘↑ does not flash a panel. Any key or click while ⌘ is down hides it
/// and keeps it hidden until ⌘ is pressed again: the chord may move the cursor or replace the
/// listing, and a panel left up would float one row's name over another.
///
/// **AppKit has no call that shows its own expansion tooltip**, which appears only on hover, so this
/// draws its own: a borderless child window at the frame the hover panel would take, whose content
/// is drawn by an `ExpandingLabelCell` holding a copy of the name. A copy rather than the row's own
/// cell, because that cell goes back to the table's reuse pool and may be showing another name by
/// the next redraw. Reusing the cell's drawing keeps the two panels identical, padding and resting
/// ink included.
@MainActor
enum CursorNamePeek {
    private static var monitors: [Any] = []
    private static var revealTimer: Timer?
    private static var panel: NSPanel?

    /// Install once, when the app starts. Later calls do nothing.
    static func install() {
        guard monitors.isEmpty else { return }
        if let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated { handleFlagsChanged(event) }
            return event
        }) {
            monitors.append(flags)
        }
        let interruptions: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        if let other = NSEvent.addLocalMonitorForEvents(matching: interruptions, handler: { event in
            MainActor.assumeIsolated { hide() }
            return event
        }) {
            monitors.append(other)
        }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { hide() }
            }
        }
    }

    /// Whether `flags` hold ⌘ and none of the other three modifier keys. Caps Lock, fn and the keypad
    /// flag are ignored: each is set by a key or a lock that has nothing to do with the hold.
    static func holdsCommandAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .option, .control, .shift]) == .command
    }

    // MARK: - Showing

    /// Float the cursor row's full name over `table`, if the Name column truncates it. `true` when a
    /// panel went up.
    @discardableResult
    static func show(for table: NSTableView) -> Bool {
        hide()
        guard let window = table.window,
              let label = cursorNameLabel(in: table),
              let frame = panelFrame(for: label) else { return false }
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.appearance = window.effectiveAppearance
        panel.contentView = NamePeekView(
            cell: snapshot(of: label),
            frame: NSRect(origin: .zero, size: frame.size)
        )
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        return true
    }

    /// Take the panel away, and forget a reveal that has not happened yet.
    static func hide() {
        revealTimer?.invalidate()
        revealTimer = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    /// The panel on screen now, if any. For tests.
    static var shownPanel: NSPanel? { panel }

    /// The cursor row's name label, when the row is on screen. `nil` for a table with no Name column,
    /// no cursor, or a cursor scrolled out of view.
    static func cursorNameLabel(in table: NSTableView) -> NSTextField? {
        let row = table.selectedRow
        let column = table.column(
            withIdentifier: NSUserInterfaceItemIdentifier(PanelViewController.Column.name.rawValue)
        )
        guard row >= 0, column >= 0, table.visibleRect.intersects(table.rect(ofRow: row)),
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: false)
              as? NSTableCellView else { return nil }
        return cell.textField
    }

    /// Where on screen the panel goes: the frame `label`'s cell asks AppKit for on hover, so the
    /// name lands over the truncated one exactly as the hover panel's does. `nil` when the name fits.
    /// Rounded out to whole points, as AppKit's own window is.
    static func panelFrame(for label: NSTextField) -> NSRect? {
        guard let cell = label.cell, let window = label.window else { return nil }
        let frame = cell.expansionFrame(withFrame: label.bounds, in: label)
        guard !frame.isEmpty else { return nil }
        return window.convertToScreen(label.convert(frame, to: nil)).integral
    }

    /// A cell drawing what `label` shows, in the ink its own cell would float.
    static func snapshot(of label: NSTextField) -> ExpandingLabelCell {
        let cell = ExpandingLabelCell(textCell: label.stringValue)
        cell.font = label.font
        cell.alignment = label.alignment
        cell.lineBreakMode = label.lineBreakMode
        cell.usesSingleLineMode = true
        cell.textColor = label.textColor
        cell.expansionInk = (label.cell as? ExpandingLabelCell)?.expansionInk
        return cell
    }

    // MARK: - Monitors

    private static func handleFlagsChanged(_ event: NSEvent) {
        guard holdsCommandAlone(event.modifierFlags), let window = event.window, window.isKeyWindow,
              let table = window.firstResponder as? FileTableView else {
            hide()
            return
        }
        // Already up, or on its way: Caps Lock or fn changing under a held ⌘ is not a new hold.
        guard revealTimer == nil, panel == nil else { return }
        let timer = Timer(timeInterval: TabShortcuts.revealDelay, repeats: false) { [weak table] _ in
            MainActor.assumeIsolated {
                revealTimer = nil
                guard let table, holdsCommandAlone(NSEvent.modifierFlags),
                      table.window?.firstResponder === table else { return }
                show(for: table)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }
}

/// The floated panel's content: the name drawn by its own `ExpandingLabelCell`, fill and border
/// included, exactly as the hover panel draws it.
private final class NamePeekView: NSView {
    private let cell: ExpandingLabelCell

    init(cell: ExpandingLabelCell, frame: NSRect) {
        self.cell = cell
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        cell.draw(withExpansionFrame: bounds, in: self)
    }
}
