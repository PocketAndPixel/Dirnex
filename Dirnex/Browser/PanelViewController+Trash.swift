import AppKit
import DirnexCore

/// The Trash, merged across volumes and shown in a virtual results tab (PLAN.md §M8 "Trash row").
///
/// macOS keeps one trash per volume — `~/.Trash` plus every mount's `.Trashes/<uid>` — and Finder
/// presents them as a single place. So does this: `SidebarLocations.trashDirectories` says which
/// ones exist, each is listed through the ordinary local backend, and the union is installed as a
/// `.trash` results tab whose entries carry their real on-disk paths. Nothing here is a new VFS
/// backend; the merge is a listing, not a filesystem.
///
/// Two behaviors make it a Trash rather than a folder view, and both fall out of existing
/// machinery rather than special cases:
///
/// - **Delete means delete.** `CompositeBackend.capabilities(for:)` grants a trash location no
///   `.trash` capability, so the M5 capability degradation already turns F8 into a confirmed
///   permanent delete. Without that, F8 here would move an item to the Trash it is already in —
///   which `FileManager` reports as a *success* while doing nothing (probed).
/// - **It re-lists after that delete**, unlike a search snapshot: what changed is what the user
///   just did in this pane, so `refreshCurrentDirectory` re-gathers the merge in place.
///
/// Reading `~/.Trash` needs Full Disk Access. Without the grant it comes back as a permission
/// error, and the pane says so through the M7 onboarding sheet instead of showing an empty Trash —
/// "there is nothing in your Trash" is a much worse answer than "I'm not allowed to look."
extension PanelViewController {
    /// Whether the active tab is showing the merged Trash.
    var isTrashListing: Bool {
        panel.path.backend == .trash
    }

    /// Open the Trash in a new virtual results tab — the sidebar's Trash row.
    func showTrash() {
        gatherTrash { [weak self] entries in
            guard let self else { return }
            openResults(entries, truncated: false, as: trashPresentation())
        }
    }

    /// Re-gather the Trash into the tab already showing it, after a delete emptied part of it.
    /// Called by `refreshCurrentDirectory`, which is the one funnel every mutation refreshes
    /// through; the cursor is re-anchored by identity by `installSortedModel`, so the row under it
    /// survives rows vanishing above it.
    func reloadTrash() {
        gatherTrash { [weak self] entries in
            guard let self, isTrashListing else { return }
            installSortedModel(resultsModel(entries, as: trashPresentation()))
        }
    }

    // MARK: - Gathering

    private func trashPresentation() -> ResultsPresentation {
        ResultsPresentation(
            backend: .trash,
            pathSummary: "Trash",
            sort: panel.model.sort,
            query: nil,
            scope: nil,
            title: "Trash",
            // The pane's own setting, not the results default: the dotfiles in a trash directory
            // are Finder's `.DS_Store` put-back databases, not files the user threw away.
            showsHidden: panel.model.showHidden
        )
    }

    /// List every existing trash directory off the main thread and hand back the union.
    ///
    /// A permission failure anywhere stops the flow and offers the Full Disk Access grant instead
    /// of delivering a partial answer: in practice the one directory that can be denied is
    /// `~/.Trash`, which is where all but a handful of trashed items live, so a "partial" Trash
    /// would be an empty one wearing a plausible face.
    private func gatherTrash(then present: @escaping ([FileEntry]) -> Void) {
        let backend = backend
        let directories = SidebarLocations.trashDirectories(volumes: SidebarLocations.volumes())
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> TrashGather in
                var entries: [FileEntry] = []
                for directory in directories {
                    do {
                        entries.append(contentsOf: try backend.listDirectory(at: directory))
                    } catch let error as VFSError {
                        if case .permissionDenied = error { return .denied }
                        // A volume unmounted between the enumeration and the listing is not worth
                        // an alert — it simply has no trash to contribute any more.
                        continue
                    } catch {
                        continue
                    }
                }
                return .listed(entries)
            }.value

            switch outcome {
            case let .listed(entries): present(entries)
            case .denied: FullDiskAccessOnboarding.presentForTrash(over: view.window)
            }
        }
    }

    /// What one pass over the trash directories produced: the merged entries, or the fact that the
    /// grant is missing. Deliberately not an `Error` — a denied read here is an answer to show the
    /// user, not a failure to report.
    private enum TrashGather: Sendable {
        case listed([FileEntry])
        case denied
    }
}
