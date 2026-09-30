import AppKit
import DirnexCore
import Photos

/// The sidebar's Photos row (PLAN.md §M28 Slice 2): ask macOS for access the first time, then list
/// the library.
extension PanelViewController {
    /// The library's root — years, and `Undated` when anything lacks a date.
    static let photosLibraryRoot = VFSPath(backend: .photos, path: "/")

    /// Open the Photos library in this pane, asking for access first if nobody has yet.
    ///
    /// **The prompt is raised here, on the click, and nowhere else.** The transport under the backend
    /// only reads the status and refuses when access is not granted (`PhotoKitLibrary`), so a restored
    /// tab, a refresh or a search never raises a system dialog nobody asked for.
    ///
    /// A refusal is deliberately not handled here: the listing fails with `permissionDenied`, and the
    /// load-failure sheet names Privacy & Security ▸ Photos — the only place it can be changed — with
    /// the same sentence a revoked grant gets later in the session.
    func showPhotosLibrary() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else {
            PhotosLibraryChangeMonitor.shared.startIfPermitted()
            navigate(to: Self.photosLibraryRoot)
            return
        }
        Task { @MainActor [weak self] in
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            // Before the navigation, so the grant just given reaches every pane already on the
            // library — a tab restored before it — and not only this one.
            PhotosLibraryChangeMonitor.shared.startIfPermitted()
            self?.navigate(to: Self.photosLibraryRoot)
            self?.focusTable()
        }
    }
}
