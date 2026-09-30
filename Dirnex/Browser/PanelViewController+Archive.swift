import DirnexCore

/// Browsing archives as folders (PLAN.md §M4 ArchiveBackend). Entering an archive file
/// navigates into its virtual `archive:…` listing (served by the pane's `CompositeBackend`);
/// walking up inside walks the inner tree and, at the archive root, exits back to the folder
/// that contains the archive.
///
/// A browsed archive is read-only this pass, so the pane recognizes it via `isArchive` and —
/// like the search-results pane (`isResultsListing`) — suppresses every directory-bound
/// mutation. `isVirtualDirectory` is the union both share: anything that needs a real,
/// writable, on-disk directory checks it.
extension PanelViewController {
    /// The active tab is browsing inside an archive's virtual contents.
    var isArchive: Bool {
        panel.path.backend.isArchive
    }

    /// The active tab shows a virtual listing — search results or a browsed archive — with no real,
    /// writable directory behind it, the gate for the New Folder / rename / paste flows to bail out
    /// early. A remote SFTP or FTP directory is *not* virtual: it's a real, writable, listable
    /// directory (just over the network), so those flows run against it through that backend's write
    /// primitives; whether an individual op is offered is decided by `capabilities(for:)`.
    var isVirtualDirectory: Bool {
        isArchive || isResultsListing
    }

    /// The archive-root location for a local archive file — the target Enter navigates to.
    func archiveRoot(for entry: FileEntry) -> VFSPath {
        VFSPath(backend: .archive(forArchiveAt: entry.path.path), path: "/")
    }

    /// Walk up one level from inside an archive, landing the cursor on the entry we came from.
    /// Returns `false` if this isn't an archive path.
    func goUpWithinArchive() -> Bool {
        guard isArchive else { return false }
        if let step = archiveParent() {
            navigate(to: step.destination, focus: step.focus)
        }
        return true
    }

    /// Where `..` leads from the archive location on screen, and the row to land on there: the
    /// parent inner directory, or — at the archive root — wherever this archive came from. For a
    /// nested archive that's the outer archive's inner directory (§M4 "nested archives"); for a
    /// top-level archive it's the on-disk folder containing the archive file. `nil` outside an
    /// archive. One answer for the walk and for the `..` row's Copy Path, so the two cannot name
    /// different places.
    func archiveParent() -> (destination: VFSPath, focus: VFSPath)? {
        guard let archivePath = panel.path.backend.archivePath else { return nil }
        if let parent = panel.parentPath, !panel.path.isRoot {
            return (parent, panel.path)
        }
        if let origin = host?.nestedArchiveRegistry.origin(ofMountAt: archivePath),
           let container = origin.parent {
            // A mount whose bytes are a temp copy — go back to wherever the file really lives,
            // onto it. For a nested archive that is the outer archive's inner directory; for one on
            // a server it is the server's own directory (PLAN.md §M24 Slice 6), which is exactly
            // what keeps the temp extraction out of the user's way up.
            return (container, origin)
        }
        // A top-level archive — exit to the containing local directory.
        let archiveFile = VFSPath.local(archivePath)
        guard let container = archiveFile.parent else { return nil }
        return (container, archiveFile)
    }

    /// The text Copy Path writes for `location` — what ``CopyPathText`` answers, handed the chain of
    /// the location's *own* archive mount. Asking per location rather than reading the pane's chain
    /// is what keeps a search hit inside a nested archive from naming its temp extraction.
    func copyPathText(for location: VFSPath) -> String {
        let ancestry = location.backend.archivePath.map {
            host?.nestedArchiveRegistry.ancestry(ofMountAt: $0) ?? []
        } ?? []
        return CopyPathText.text(for: location, archiveAncestry: ancestry)
    }
}
