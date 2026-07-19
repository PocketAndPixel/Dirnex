import AppKit
import DirnexCore

/// The path bar's delegate: activating a crumb navigates the pane, and the bar's inline
/// editor asks the pane for the child directories to autocomplete. Split into its own
/// file (like `+Table`, `+Chrome`, `+ParentRow`) to keep the controller proper focused
/// on the cursor/selection plumbing.
extension PanelViewController: PathBarViewDelegate {
    func pathBar(_ bar: PathBarView, didActivate path: VFSPath) {
        // Landing on the branch we came from (when the path is an ancestor of the
        // current directory) makes a multi-level crumb jump feel like walking up.
        let focus = path.child(towards: panel.path)
        navigate(to: path, focus: focus)
        focusTable()
    }

    func pathBar(_ bar: PathBarView, didCommit rawText: String, resolved: VFSPath) {
        Task {
            // An explicit path that names a real directory always wins over a fuzzy guess.
            if let entry = await DirectoryLoader.stat(backend, at: resolved), entry.isDirectoryLike {
                navigate(to: resolved)
                focusTable()
                return
            }
            // A bare, slash-free fragment ("dl") that didn't resolve is treated as a frecency
            // query — jump to the best-scored visited directory whose name fuzzily matches
            // (zoxide-style). A path with a slash is taken literally, so a mistyped explicit
            // path surfaces the normal not-found sheet instead of leaping somewhere else.
            if !rawText.contains("/"), let match = await firstExistingFrecencyMatch(for: rawText) {
                navigate(to: match)
                focusTable()
                return
            }
            // Nothing matched — navigate to the typed path so the standard not-found sheet shows.
            navigate(to: resolved)
            focusTable()
        }
    }

    /// The best-scored frecency directory for `fragment` that still exists on disk. Walks the
    /// ranked candidates because a top match may have been deleted since it was last visited
    /// (frecency's index outlives the folders it remembers); capped so a pathological miss
    /// doesn't fan out into a long stat storm.
    private func firstExistingFrecencyMatch(for fragment: String) async -> VFSPath? {
        for path in FrecencyStore.shared.rankedMatches(for: fragment).prefix(10) {
            if let entry = await DirectoryLoader.stat(backend, at: path), entry.isDirectoryLike {
                return path
            }
        }
        return nil
    }

    func pathBarDidCancel(_ bar: PathBarView) {
        focusTable()
    }

    func pathBarDidBeginEditing(_ bar: PathBarView) {
        host?.panelDidBecomeActive(self)
    }

    func pathBar(_ bar: PathBarView, childDirectoriesOf directory: VFSPath) async -> [String] {
        let showHidden = panel.model.showHidden
        do {
            let listing = try await DirectoryLoader.list(backend, at: directory)
            return listing.entries
                .filter { $0.isDirectoryLike && (showHidden || !$0.isHidden) }
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            return []
        }
    }
}
