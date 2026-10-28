import AppKit
import DirnexCore

/// A lone tap of ⌥ opens the context menu over the cursor row, in the pane whose file list has the
/// focus (2026-10-25), and a second tap closes it (`OptionTapMenuCloser`). The keyboard had no way
/// to that menu: a Mac has no menu key, and Total Commander's ⇧F10 was left alone because the F-keys
/// are kept for commands.
///
/// What counts as a tap is `ModifierTap`'s rule, fed by one local monitor the way `CursorNamePeek`
/// is fed: the modifier changes, plus everything that spoils a tap (a key, a click, a scroll). A tap
/// lasts at most ``TabShortcuts/revealDelay``, the hold that shows a dialog's tab numbers, so the app
/// draws one line between a tap and a hold.
///
/// **The menu opens on the release, a run-loop turn later.** By then the monitor has returned and
/// the release has been delivered, so the menu's own event loop starts with nothing pending. Only a
/// file list with the focus answers; a field editor, a sheet or the sidebar holding it opens nothing.
@MainActor
enum OptionTapMenu {
    private static var monitors: [Any] = []
    private static var tap = recognizer()

    /// A recognizer for ⌥ with the app's tap length.
    static func recognizer() -> ModifierTap {
        ModifierTap(modifier: .option, maximumDuration: TabShortcuts.revealDelay)
    }

    /// Install once, when the app starts. Later calls do nothing.
    static func install() {
        guard monitors.isEmpty else { return }
        let watched: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: watched, handler: { event in
            MainActor.assumeIsolated { _ = handle(event) }
            return event
        }) {
            monitors.append(monitor)
        }
        // A release made while another app was active never reaches this one, so the recognizer
        // starts again from the keyboard as it is when the app comes back.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { resetFromKeyboard() }
        }
    }

    /// Move the app's recognizer along with `event`, and open the menu when it ends a tap in a file
    /// list holding the focus. `true` when it ended a tap.
    static func handle(_ event: NSEvent) -> Bool {
        let ended = ends(event, tap: &tap)
        if ended, let table = focusedTable(in: event.window) {
            open(for: table)
        }
        return ended
    }

    /// Start the app's recognizer again from the keyboard as it is now, after a stretch in which
    /// events went past the monitor. That is any time another app was active, and any time a
    /// context menu was open: it runs its own event loop. Seen 2026-10-25: ⌥ pressed in the list,
    /// let go inside a right-click menu, left the recognizer holding ⌥, and the next tap opened
    /// nothing.
    static func resetFromKeyboard() {
        tap.reset(holding: modifiers(of: NSEvent.modifierFlags))
    }

    // MARK: - Deciding

    /// Whether `event` ends a tap, moving `tap` along. Any event but a modifier change spoils the
    /// press under way.
    static func ends(_ event: NSEvent, tap: inout ModifierTap) -> Bool {
        guard event.type == .flagsChanged else {
            tap.interrupt()
            return false
        }
        return tap.modifiersChanged(to: modifiers(of: event.modifierFlags), at: event.timestamp)
    }

    /// The four modifier keys `flags` holds. Caps Lock, fn and the keypad flag are left out: none of
    /// them says a modifier key is down.
    static func modifiers(of flags: NSEvent.ModifierFlags) -> CommandShortcut.Modifiers {
        var modifiers: CommandShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    /// The file list holding the focus in `window`, or `nil` when something else holds it.
    static func focusedTable(in window: NSWindow?) -> FileTableView? {
        window?.firstResponder as? FileTableView
    }

    // MARK: - Opening

    /// Open the menu of `table`'s pane a turn later, if the table still has the focus then.
    private static func open(for table: FileTableView) {
        DispatchQueue.main.async { [weak table] in
            guard let table, let window = table.window, window.isKeyWindow,
                  focusedTable(in: window) === table else { return }
            NSApp.sendAction(
                #selector(PanelViewController.showContextMenu(_:)),
                to: nil,
                from: table
            )
        }
    }
}
