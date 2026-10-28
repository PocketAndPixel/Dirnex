import AppKit
import DirnexCore

/// Closes the pane's context menu on a lone tap of ⌥, as Escape does (2026-10-25), so the key that
/// opens it from the keyboard also puts it away. It closes the menu however it was opened: a tap,
/// File ▸ Show Context Menu, or a right-click.
///
/// An open menu runs its own event loop, and no local monitor sees its events: measured 2026-10-25,
/// ↓ and Escape pressed in the menu never reached `OptionTapMenu`'s. So while the menu is open a
/// timer samples the keyboard instead (`PolledModifierTap`). It reads the modifiers held, and the
/// system's running counts of key presses, clicks and scrolls, which spoil a tap as they do outside
/// the menu. The counts are the system's own statistics and need no Input Monitoring permission.
@MainActor
final class OptionTapMenuCloser: NSObject, NSMenuDelegate {
    /// The delegate of every context menu; only one is ever open.
    static let shared = OptionTapMenuCloser()

    /// How often the keyboard is sampled while a menu is open. A tap lasts some 100 ms.
    static let sampleInterval: TimeInterval = 0.01

    private var watch: PolledModifierTap?
    private var timer: Timer?
    private weak var menu: NSMenu?

    func menuWillOpen(_ menu: NSMenu) {
        self.menu = menu
        watch = PolledModifierTap(
            modifier: .option,
            maximumDuration: TabShortcuts.revealDelay,
            holding: OptionTapMenu.modifiers(of: NSEvent.modifierFlags),
            inputCount: Self.inputCount()
        )
        // `.common` takes in the event-tracking mode an open menu runs the loop in. A timer in the
        // default mode alone would never fire while the menu is up.
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        timer?.invalidate()
        timer = nil
        watch = nil
        // The menu's own event loop kept every key from the app's monitor, so what it last saw
        // held may be stale.
        OptionTapMenu.resetFromKeyboard()
    }

    private func sample() {
        guard var watch else { return }
        let ended = watch.sample(
            holding: OptionTapMenu.modifiers(of: NSEvent.modifierFlags),
            inputCount: Self.inputCount(),
            at: ProcessInfo.processInfo.systemUptime
        )
        self.watch = watch
        if ended { menu?.cancelTracking() }
    }

    /// Key presses, clicks and scrolls so far in the login session, from any app. Only whether it
    /// moved is read: while a menu is open, this app is the one taking them.
    static func inputCount() -> Int {
        let types: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        return types.reduce(0) {
            $0 + Int(CGEventSource.counterForEventType(.combinedSessionState, eventType: $1))
        }
    }
}
