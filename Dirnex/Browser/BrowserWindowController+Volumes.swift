import AppKit
import DirnexCore

/// Recover a pane the instant the volume it's browsing goes away — ejected from the sidebar, in
/// Finder, or via `diskutil`. A pane left sitting on a vanished mount keeps showing a stale
/// listing it can no longer act on (the symptom that motivated this: the file is still visible
/// but every operation fails). Watching the workspace's unmount notification, rather than only
/// the sidebar's own eject button, covers every way a volume can disappear; both panes are asked
/// to send any tab pointed inside the mount back to Home.
extension BrowserWindowController {
    func observeVolumeUnmount() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeDidUnmount(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    @objc private func volumeDidUnmount(_ notification: Notification) {
        guard let mountPath = Self.unmountedVolumePath(from: notification) else { return }
        let mountPoint = VFSPath.local(mountPath)
        leftPanel.recoverIfBrowsing(unmountedVolumeAt: mountPoint)
        rightPanel.recoverIfBrowsing(unmountedVolumeAt: mountPoint)
    }

    /// The mount-point path of the just-unmounted volume. `volumeURLUserInfoKey` carries it on
    /// modern macOS; the legacy `NSDevicePath` string is a fallback for older payloads.
    private static func unmountedVolumePath(from notification: Notification) -> String? {
        if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            return url.path
        }
        return notification.userInfo?["NSDevicePath"] as? String
    }
}
