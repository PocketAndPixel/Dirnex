import AppKit

/// ⌘1 through ⌘9 pick a dialog's tabs, and holding ⌘ shows which number is which.
///
/// Get Info and Settings are the windows with tabs, and neither had a keyboard route between them
/// that did not pass through the selector with Tab and the arrows. ⌘ plus the tab's position is the
/// convention Safari and Terminal already use, and none of ⌘1–⌘9 is bound to a command here, so in a
/// dialog the chord is free. A command the user rebinds onto one of them still works everywhere but
/// in a window whose tabs claim it.
///
/// **Local monitors, not key equivalents**, because the tab views are AppKit's and SwiftUI's rather
/// than ours, and a monitor sees the key ahead of the menu bar whatever holds focus — a text field in
/// the middle of an edit included, the same as ⌘-number in a browser.
///
/// **The numbers wait ``revealDelay`` before appearing**, so a quick ⌘C or ⌘W does not flash badges
/// across the tabs. The timer is scheduled in the common run-loop modes: Get Info is an app-modal
/// window, and a timer in the default mode never fires while one is up (docs/NOTES.md ▸ AppKit).
///
/// Scoped like ``KeyboardReachableControls``: the browser window is left alone, since its tabs and
/// its keys are its own.
@MainActor
enum TabShortcuts {
    /// How long ⌘ has to be held before the numbers appear.
    static let revealDelay: TimeInterval = 0.4

    /// What a number past the last tab does. A seam so the test host stays quiet.
    static var refuse: () -> Void = { NSSound.beep() }

    private static var monitors: [Any] = []
    private static var revealTimer: Timer?
    private static var shownOn: NSTabView?

    /// The top-row digit keys by virtual key code, for layouts whose digits need Shift — AZERTY's
    /// `1` key types `&`, and ⌘ does not change that.
    private static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9
    ]

    /// Install once, when the app starts. Later calls do nothing.
    static func install() {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            let handled = MainActor.assumeIsolated { handleKeyDown(event) }
            return handled ? nil : event
        }) {
            monitors.append(keys)
        }
        if let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated { handleFlagsChanged(event) }
            return event
        }) {
            monitors.append(flags)
        }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { hideNumbers() }
            }
        }
    }

    // MARK: - Deciding

    /// The tab number `event` asks for: ⌘ alone with a digit from 1 to 9, by character or by key.
    static func tabNumber(for event: NSEvent) -> Int? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.type == .keyDown, modifiers == .command else { return nil }
        if let character = event.charactersIgnoringModifiers, character.count == 1,
           let digit = Int(character), (1...9).contains(digit) {
            return digit
        }
        return digitKeyCodes[event.keyCode]
    }

    /// The tabs a window's ⌘-numbers pick: its first visible tab view with more than one tab, unless
    /// the window is the browser.
    static func tabView(in window: NSWindow) -> NSTabView? {
        guard !(window.windowController is PaneKeyWindowController),
              let content = window.contentView else { return nil }
        return tabView(within: content)
    }

    /// The first visible tab view with more than one tab at or under `view`.
    static func tabView(within view: NSView) -> NSTabView? {
        if let tabs = view as? NSTabView, !tabs.isHiddenOrHasHiddenAncestor, tabs.numberOfTabViewItems > 1 {
            return tabs
        }
        for subview in view.subviews {
            if let found = tabView(within: subview) { return found }
        }
        return nil
    }

    /// Answer `event` for `window`: pick the tab it names and report the key handled, or report it
    /// not handled so it travels on as usual.
    ///
    /// **Every ⌘1–⌘9 is claimed in a window with tabs, including a number past the last tab**, which
    /// beeps. Letting those through was measured to be worse than inconsistent: with four tabs, ⌘7
    /// reached the focused date picker in Get Info, which ignores ⌘ and took the 7 as the day. A
    /// tabless dialog whose controller is ``ClaimsTabNumberKeys`` is refused the same way, for the
    /// same date picker.
    static func perform(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let number = tabNumber(for: event) else { return false }
        if let tabs = tabView(in: window) {
            pick(number, in: tabs)
            return true
        }
        guard window.contentViewController is ClaimsTabNumberKeys else { return false }
        refuse()
        return true
    }

    /// Select tab `number` of `tabs`, counting from 1, or refuse a number past the last tab.
    static func pick(_ number: Int, in tabs: NSTabView) {
        if number <= tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: number - 1)
        } else {
            refuse()
        }
    }

    // MARK: - Monitors

    private static func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow else { return false }
        let handled = perform(event, in: window)
        if !handled, tabNumber(for: event) == nil {
            // Any other key with ⌘ down is a chord, not a look at the numbers.
            hideNumbers()
        }
        return handled
    }

    private static func handleFlagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command, let window = event.window, window.isKeyWindow,
              let tabs = tabView(in: window) else {
            hideNumbers()
            return
        }
        guard revealTimer == nil, shownOn == nil else { return }
        let timer = Timer(timeInterval: revealDelay, repeats: false) { [weak tabs] _ in
            MainActor.assumeIsolated {
                revealTimer = nil
                guard let tabs, NSEvent.modifierFlags.intersection(
                    [.command, .option, .control, .shift]
                )
                    == .command else { return }
                showNumbers(on: tabs)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    // MARK: - Numbers

    /// Put a number on each of `tabs`' tabs.
    static func showNumbers(on tabs: NSTabView) {
        hideNumbers()
        let rects = TabNumberBadge.tabRects(in: tabs)
        guard rects.count == tabs.numberOfTabViewItems else { return }
        for (index, rect) in rects.enumerated() where index < 9 {
            let badge = TabNumberBadge(number: index + 1)
            badge.frame = TabNumberBadge.frame(
                forTab: rect,
                in: TabNumberBadge.room(in: tabs),
                flipped: tabs.isFlipped
            )
            tabs.addSubview(badge, positioned: .above, relativeTo: nil)
        }
        shownOn = tabs
    }

    /// Take the numbers away, and forget a reveal that has not happened yet.
    static func hideNumbers() {
        revealTimer?.invalidate()
        revealTimer = nil
        shownOn?.subviews.filter { $0 is TabNumberBadge }.forEach { $0.removeFromSuperview() }
        shownOn = nil
    }
}

/// A dialog with no tabs that still claims ⌘1–⌘9, refusing them with a beep rather than letting them
/// reach whatever holds focus.
///
/// The remote Get Info is the one that needs it: it is a single page where the local panel has four
/// tabs, and over FTP it offers an `NSDatePicker` for the modification time — which ignores ⌘ and
/// takes a digit as part of the date, the fall-through ``TabShortcuts`` already stops in the tabbed
/// panels. Adopted by the window's content view controller, which is where a presented dialog lives
/// (probed: `presentAsModalWindow` makes the presented controller its window's
/// `contentViewController`).
@MainActor
protocol ClaimsTabNumberKeys: NSViewController {}
