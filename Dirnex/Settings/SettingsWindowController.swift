import AppKit
import SwiftUI

/// Hosts the SwiftUI `SettingsView` in a standard preferences window. A single shared instance
/// so ⌘, (and the palette's "Settings…") focuses the existing window rather than stacking
/// duplicates — the AppKit equivalent of SwiftUI's `Settings` scene, which this AppKit-hosted
/// app can't use directly.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(
            rootView: SettingsView(
                keyBindings: .shared,
                preferences: .shared
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var hasPlaced = false
    private let escapeMonitor = EscapeToCloseMonitor()

    /// Bring the Settings window to the front, placing it the first time it appears. The SwiftUI
    /// content only sizes the window once its hosting view lays out — which `showWindow` does too
    /// late — so force that layout and adopt the content's fitting size here, *then* place it,
    /// before the window is shown. Placing earlier (or after `showWindow`) lands a
    /// placeholder-sized window off-centre, which is what a not-yet-laid-out window does.
    ///
    /// It takes the same placement as the dialogs — where the user last dragged it, else centred on
    /// the app's window. The window itself is not resizable, which is what makes the restore
    /// position-only (see ``DialogWindowPlacement``).
    func present() {
        if !hasPlaced, let window, let content = window.contentViewController?.view {
            content.layoutSubtreeIfNeeded()
            let fitting = content.fittingSize
            if fitting.width > 0, fitting.height > 0 { window.setContentSize(fitting) }
            DialogWindowPlacement.place(window, key: "Settings", centeredOver: NSApp.mainWindow)
            hasPlaced = true
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Installed per appearance rather than once, so no monitor is live while Settings is closed.
        // `install` replaces any previous one, so re-presenting cannot stack them.
        if let window {
            escapeMonitor.install(for: window) { [weak window] in window?.performClose(nil) }
        }
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        escapeMonitor.remove()
    }
}
