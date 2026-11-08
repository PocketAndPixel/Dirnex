import AppKit

/// Keeps a compare window visible over an app-modal window such as the Synchronize window (PLAN.md
/// §M31 Slice 4).
///
/// `CompareWindow.worksWhenModal` lets the window take clicks and keys while that window is up, and
/// this lets it be seen: the Synchronize window sits at the modal-panel level (8), above every
/// normal window, so a window at the normal level opened behind it and stayed there when clicked.
/// Seen live and measured with `CGWindowListCopyWindowInfo` on 2026-10-22. So the window opens at the
/// modal window's level, and drops back to the normal level once no window is modal, rather than
/// floating above the browser window for the rest of its life.
@MainActor
final class ModalLevelKeeper {
    private var observer: (any NSObjectProtocol)?

    /// Put `window` at the level of the app-modal window in front, if there is one above it.
    func raise(_ window: NSWindow) {
        guard let modal = NSApp.modalWindow, modal.level > window.level else { return }
        window.level = modal.level
        // Posted after every event the app handles, so the level comes back down on the first event
        // after the modal window has gone. Watched only while the window is raised.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: NSApp,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow == nil else { return }
                window?.level = .normal
                self?.stop()
            }
        }
    }

    /// Stop watching, leaving the window at the level it is at.
    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}
