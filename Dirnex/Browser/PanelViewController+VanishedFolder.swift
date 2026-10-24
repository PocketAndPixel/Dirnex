import DirnexCore

/// A refresh that finds the pane's folder gone moves the pane up to the nearest folder that still
/// exists, instead of leaving the old rows on screen with nothing behind them.
///
/// Every refresh path used to read a failed listing as "keep what you have", which is right for a
/// server that did not answer and wrong for a folder that is not there any more. Seen 2026-10-24:
/// Put Back emptied a NAS `#recycle` folder and pruned it while a pane was showing it, and the pane
/// went on listing the file that had just left. The same held on this disk, where the watcher does
/// fire for its own folder being deleted (`kFSEventStreamCreateFlagWatchRoot`).
///
/// Whether the folder is really gone, and where to go, is `FolderRefuge`'s, which asks the backend
/// before it believes a failed listing. Silent, as Total Commander and Finder are: the path bar
/// and the rows say where the pane is now.
extension PanelViewController {
    /// The re-list a list-mode refresh of `path` asked for, or `nil` when it failed, in which case
    /// the failure has gone to ``leaveVanishedFolder(_:after:token:)``. The one spelling the
    /// watcher, the poll, an operation's refresh and a tab switch share, so none of them can go back
    /// to dropping the error.
    func refreshedModel(
        at path: VFSPath,
        sort: FileSort,
        showHidden: Bool,
        sizes: [VFSPath: Int64],
        token: Int
    ) async -> DirectoryModel? {
        do {
            return try await DirectoryLoader.model(
                backend, at: path, sort: sort, showHidden: showHidden, directorySizes: sizes
            )
        } catch {
            leaveVanishedFolder(path, after: error, token: token)
            return nil
        }
    }

    /// A refresh of `path` failed with `error`. When that says the folder is gone, and the backend
    /// confirms it, move the pane to the nearest folder above it that still exists. `error` is `nil`
    /// for a tree refresh, which learns only that its root did not list, so there the confirmation
    /// is the whole of the evidence.
    ///
    /// `token` is the one the refresh was planned under: if anything has moved the pane since, the
    /// walk's answer is about a pane that no longer exists, and nothing happens.
    ///
    /// **Only a pane in a window moves**, visible or not, the line the remote poll draws for the
    /// same reason (`isRemoteRefreshWanted`): a pane in no window is one nobody is looking at, and
    /// it is the shape every app test builds. Those panes outlive their tests. Measured 2026-10-25
    /// without this guard: as each fixture was deleted they walked up into the temp folder, a tree
    /// pane there re-sorted tens of thousands of rows on the main actor at every other test's write,
    /// and unrelated suites timed out waiting for their own listings.
    func leaveVanishedFolder(_ path: VFSPath, after error: (any Error)?, token: Int) {
        guard token == loadToken, panel.path == path, viewIfLoaded?.window != nil else { return }
        if let error, (error as? VFSError)?.meansPlaceIsGone != true { return }
        // Only a real directory has an "above". A browsed archive, a results tab and the merged
        // listings have their own ways of going stale and are not walked out of.
        guard path.backend == .local || path.backend.isRemoteConnection else { return }
        let tabIndex = activeTabIndex
        let backend = backend
        Task {
            let refuge = await BlockingWork.run {
                FolderRefuge.nearestExisting(above: path) { try backend.stat(at: $0) }
            }
            guard let refuge, token == loadToken, panel.path == path,
                  activeTabIndex == tabIndex else { return }
            navigate(to: refuge)
        }
    }
}
