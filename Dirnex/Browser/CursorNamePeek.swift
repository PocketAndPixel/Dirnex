import AppKit

/// Holding ⌘ floats the full name of the cursor row when the Name column cuts it short, in the
/// panel a hover floats (`ExpansionPanel`), reached from the keyboard. A file manager driven from the
/// keys otherwise had no way to read a truncated name without the mouse or a wider column.
///
/// **It waits ``TabShortcuts/revealDelay`` before appearing**, the same hold that shows a dialog's tab
/// numbers, so a quick ⌘C or ⌘↑ does not flash a panel. Any key or click while ⌘ is down hides it
/// and keeps it hidden until ⌘ is pressed again: the chord may move the cursor or replace the
/// listing, and a panel left up would float one row's name over another.
@MainActor
enum CursorNamePeek {
    private static var monitors: [Any] = []
    private static var revealTimer: Timer?

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
        guard let label = cursorNameLabel(in: table) else { return false }
        return ExpansionPanel.show(over: label, for: .commandHold)
    }

    /// Take the hold's panel away, and forget a reveal that has not happened yet. A hover's panel is
    /// left alone.
    static func hide() {
        revealTimer?.invalidate()
        revealTimer = nil
        ExpansionPanel.hide(ifShownBy: .commandHold)
    }

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

    // MARK: - Monitors

    private static func handleFlagsChanged(_ event: NSEvent) {
        guard holdsCommandAlone(event.modifierFlags), let window = event.window, window.isKeyWindow,
              let table = window.firstResponder as? FileTableView else {
            hide()
            return
        }
        // Already up, or on its way: Caps Lock or fn changing under a held ⌘ is not a new hold.
        guard revealTimer == nil, ExpansionPanel.owner != .commandHold else { return }
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
