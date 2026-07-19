import AppKit
import DirnexCore

/// Total Commander's Space-on-directory in-place sizing (PLAN.md §M1 "Space-on-dir
/// in-place size"). Pressing Space on a folder marks it (the normal mark-and-advance
/// gesture) and, here, kicks off a background recursive walk; when the byte total
/// lands it replaces the folder's dash in the size column and joins any size-sort.
///
/// The heavy lifting is `DirnexCore.DirectorySizer` (headless, tested); this shell
/// only schedules it off the main thread and applies the result if the pane is still
/// showing the same directory. It follows the pane's existing background pattern —
/// spawn a task, guard on completion via `loadToken` + path — rather than adding a
/// separate cancellation channel.
extension PanelViewController {
    /// Size the directory `entry` unless it already carries a computed total. Cheap to
    /// call on a re-press: once a size exists the guard makes it a no-op, so marking a
    /// run of folders never re-walks one that was already sized.
    func computeDirectorySize(for entry: FileEntry) {
        guard panel.model.computedSize(of: entry) == nil else { return }
        let path = entry.path
        let directory = panel.path
        let token = loadToken
        Task {
            guard let bytes = await DirectoryLoader.size(backend, of: path) else { return }
            // Discard a total that resolved after the user navigated away or switched
            // tabs — both bump `loadToken`; the path check is belt-and-suspenders.
            guard token == loadToken, panel.path == directory else { return }
            if deferRefreshIfRenaming() { return }
            reconcileCursorFromTable()
            panel.setDirectorySize(path, bytes: bytes)
            // A size can reorder the list (when sorting by size), so re-render — but as
            // a background refresh that never scrolls, so the number appears without
            // yanking the user's position.
            renderRefresh()
        }
    }
}
