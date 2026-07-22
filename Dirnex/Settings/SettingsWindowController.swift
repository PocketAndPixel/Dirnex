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
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Bring the Settings window to the front, centering it the first time it appears.
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
