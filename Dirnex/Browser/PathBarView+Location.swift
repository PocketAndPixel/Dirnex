import AppKit
import DirnexCore

/// How each kind of location renders in the path bar: a real directory's clickable breadcrumbs, a
/// browsed archive's mixed-backend trail, and a search snapshot's dead-end label. Split from the
/// view proper (like `+Table`/`+Chrome` around the pane) so `PathBarView` stays the editor, the
/// crumb plumbing and the branch chip, and this stays the location vocabulary.
extension PathBarView {
    /// Dispatch the location render by backend: clickable breadcrumbs for a local directory or a
    /// browsed archive (whose trail spans the archive's local ancestors, then its inner path), a
    /// non-clickable label for a search-results snapshot.
    func rebuildContents(for path: VFSPath, archiveAncestry: [VFSPath] = []) {
        if path.backend == .local {
            rebuildCrumbs(for: path)
        } else if path.backend.isArchive {
            rebuildArchiveLabel(for: path, ancestry: archiveAncestry)
        } else if let location = path.backend.sftpLocation {
            // A remote SFTP location is re-listable, so it gets clickable breadcrumbs rooted at the
            // account (`oleg@mac › Users › oleg › Dev`), like a local path — not the dead-end
            // "results" label a search snapshot gets.
            rebuildCrumbs(for: path, rootTitle: "\(location.username)@\(location.host)")
        } else {
            rebuildVirtualLabel(for: path)
        }
    }

    /// Render a virtual location (Spotlight results, Recents, the merged Trash) as a single,
    /// non-clickable label — there is no ancestor chain to walk into, so the breadcrumb affordance
    /// would only mislead.
    ///
    /// The Trash names itself instead of borrowing the results phrasing: "Results for Trash" reads
    /// as a search someone ran, which is neither what it is nor how it behaves (it re-lists after a
    /// delete, where a search snapshot doesn't). Each carries the SF Symbol of the sidebar row that
    /// opens it — `trash` and `magnifyingglass` — rather than an emoji, which is a different type
    /// vocabulary that neither tints with the pane's active state nor matches the sidebar.
    func rebuildVirtualLabel(for path: VFSPath) {
        if path.backend == .trash {
            installVirtualLabel("Trash", symbolNamed: "trash")
        } else if path.backend == .icloud {
            // Same reasoning as the Trash, and the same symbol its sidebar row carries: iCloud Drive
            // is a place the user opened, not a query someone ran (PLAN.md §M9).
            installVirtualLabel("iCloud Drive", symbolNamed: "icloud")
        } else {
            installVirtualLabel("Results for \(path.lastComponent)", symbolNamed: "magnifyingglass")
        }
    }

    /// Render a browsed archive as a full, clickable breadcrumb trail — styled exactly like a
    /// local path (`Macintosh HD › Users › oleg › Downloads › pkg.zip › folder`). The trail
    /// carries the archive's real on-disk ancestors, then crosses into the archive at its own
    /// filename, then walks the inner tree. Every crumb navigates: a local ancestor exits the
    /// archive to that folder, the archive-name crumb re-enters its root, an inner crumb jumps
    /// within it — the same affordance the local path bar gives.
    func rebuildArchiveLabel(for path: VFSPath, ancestry: [VFSPath] = []) {
        installCrumbs(Self.archiveCrumbs(for: path, ancestry: ancestry))
    }

    /// The crumb chain for a browsed archive, outermost local folder → current inner directory.
    ///
    /// For a nested archive (§M4), `ancestry` carries the enclosing members outermost-first. The
    /// backends the chain crosses are `ancestry[i].backend` for each outer frame plus `path.backend`
    /// for the current (innermost) one; member `ancestry[i].path`'s last component is the next
    /// inner-archive file, so it doubles as frame `i+1`'s archive-name crumb, and that crumb's
    /// target is frame `i+1`'s root — every target is a directly navigable location.
    ///
    /// `static` and pure (no view state) so it's unit-testable without instantiating the view.
    static func archiveCrumbs(for path: VFSPath, ancestry: [VFSPath]) -> [Crumb] {
        // The outermost archive's real on-disk path — the local file the whole chain roots at.
        guard let outerOnDisk = ancestry.first?.backend.archivePath ?? path.backend.archivePath else {
            let name = (path.backend.archivePath as NSString?)?.lastPathComponent ?? "Archive"
            return [Crumb(title: name, target: path)]
        }

        // 1. The archive file's containing folders, so the trail reads as a full path before it
        //    crosses into the archive. Drop the file itself — it becomes the first archive crumb.
        var crumbs = VFSPath.local(outerOnDisk).ancestorsFromRoot.dropLast().map { ancestor in
            Crumb(title: ancestor.isRoot ? "Macintosh HD" : ancestor.lastComponent, target: ancestor)
        }

        // 2. Each archive in the chain, outermost → current.
        let backends = ancestry.map(\.backend) + [path.backend]
        for (index, backend) in backends.enumerated() {
            // The archive-name crumb — its own filename, navigating to this archive's root.
            let name = index == 0
                ? (outerOnDisk as NSString).lastPathComponent
                : (ancestry[index - 1].path as NSString).lastPathComponent
            crumbs.append(Crumb(title: name, target: VFSPath(backend: backend, path: "/")))

            // The inner directories browsed within this archive: down to (but not including) the
            // nested-archive file for an outer frame, the full browsed location for the current one.
            let isCurrentFrame = index == ancestry.count
            let innerPath = isCurrentFrame ? path.path : ancestry[index].path
            var components = innerPath.split(separator: "/", omittingEmptySubsequences: true).map(
                String.init
            )
            if !isCurrentFrame { components.removeLast() } // the nested-archive file, next frame's crumb
            var cumulative = ""
            for component in components {
                cumulative += "/" + component
                crumbs.append(
                    Crumb(title: component, target: VFSPath(backend: backend, path: cumulative))
                )
            }
        }
        return crumbs
    }
}
