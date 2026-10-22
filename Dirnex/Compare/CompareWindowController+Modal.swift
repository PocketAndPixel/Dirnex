import AppKit

/// The compare window opened from an app-modal window, such as the Synchronize window's Compare
/// Contents… (PLAN.md §M31 Slice 4).
///
/// `CompareWindow.worksWhenModal` lets it take clicks and keys while that window is up, and this
/// lets it be seen: the Synchronize window sits at the modal-panel level (8), above every normal
/// window, so a compare window at the normal level opened behind it and stayed there when clicked.
/// Seen live and measured with `CGWindowListCopyWindowInfo` on 2026-10-22. So the window opens at
/// the modal window's level, and drops back to the normal level once no window is modal, rather
/// than floating above the browser window for the rest of its life.
extension CompareWindowController {
    /// Put the window at the level of the app-modal window in front, if there is one above it.
    func raiseAboveModalWindow() {
        guard let window, let modal = NSApp.modalWindow, modal.level > window.level else { return }
        window.level = modal.level
        // Posted after every event the app handles, so the level comes back down on the first event
        // after the modal window has gone. Watched only while the window is raised.
        modalLevelObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow == nil else { return }
                self?.window?.level = .normal
                self?.stopWatchingModalWindow()
            }
        }
    }

    func stopWatchingModalWindow() {
        if let modalLevelObserver {
            NotificationCenter.default.removeObserver(modalLevelObserver)
        }
        modalLevelObserver = nil
    }
}
