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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var hasCentered = false

    /// Bring the Settings window to the front, centering it the first time it appears. The SwiftUI
    /// content only sizes the window once its hosting view lays out — which `showWindow` does too
    /// late — so force that layout and adopt the content's fitting size here, *then* centre, before
    /// the window is shown. Centering earlier (or after `showWindow`) lands a placeholder-sized
    /// window off-centre, which is what a not-yet-laid-out window does.
    func present() {
        if !hasCentered, let window, let content = window.contentViewController?.view {
            content.layoutSubtreeIfNeeded()
            let fitting = content.fittingSize
            if fitting.width > 0, fitting.height > 0 { window.setContentSize(fitting) }
            window.centerOnScreen()
            hasCentered = true
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
