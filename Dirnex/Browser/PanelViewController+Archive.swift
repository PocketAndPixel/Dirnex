import AppKit
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
    /// early. A remote SFTP directory is *not* virtual: it's a real, writable, listable directory
    /// (just over the network), so those flows run against it through the SFTP backend's write
    /// primitives; whether an individual op is offered is decided by `capabilities(for:)`.
    var isVirtualDirectory: Bool {
        isArchive || isResultsListing
    }

    /// The archive-root location for a local archive file — the target Enter navigates to.
    func archiveRoot(for entry: FileEntry) -> VFSPath {
        VFSPath(backend: .archive(forArchiveAt: entry.path.path), path: "/")
    }

    /// Walk up one level from inside an archive: to the parent inner directory, or — at the
    /// archive root — out to wherever this archive came from, landing the cursor on the entry we
    /// came from. For a nested archive that's the outer archive's inner directory (§M4 "nested
    /// archives"); for a top-level archive it's the on-disk folder containing the archive file.
    /// Returns `false` if this isn't an archive path.
    func goUpWithinArchive() -> Bool {
        guard let archivePath = panel.path.backend.archivePath else { return false }
        if let parent = panel.parentPath, !panel.path.isRoot {
            navigate(to: parent, focus: panel.path)
        } else if let origin = host?.nestedArchiveRegistry.origin(ofMountAt: archivePath),
                  let container = origin.parent {
            // A nested mount — go back to the outer archive's inner directory, onto the member.
            navigate(to: container, focus: origin)
        } else {
            // A top-level archive — exit to the containing local directory.
            let archiveFile = VFSPath.local(archivePath)
            guard let container = archiveFile.parent else { return true }
            navigate(to: container, focus: archiveFile)
        }
        return true
    }
}
