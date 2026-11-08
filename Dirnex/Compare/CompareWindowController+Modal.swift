import AppKit

/// The compare window opened from an app-modal window, such as the Synchronize window's Compare
/// Contents… (`ModalLevelKeeper`).
extension CompareWindowController {
    /// Put the window at the level of the app-modal window in front, if there is one above it.
    func raiseAboveModalWindow() {
        guard let window else { return }
        modalLevel.raise(window)
    }

    func stopWatchingModalWindow() {
        modalLevel.stop()
    }
}
