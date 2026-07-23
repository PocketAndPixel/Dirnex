import AppKit
import DirnexCore

/// Browsing an archive nested inside another (PLAN.md §M4 "nested archives — browse/extract a zip
/// inside a zip"). An inner archive has no on-disk path of its own — its bytes are a member of the
/// outer archive — so entering it first extracts that member to a temp file (with `bsdtar`, via
/// `ArchiveExtractor`, exactly like Quick Look inside and F5 copy-out) and then browses *that*
/// file's virtual contents. The window's `NestedArchiveRegistry` remembers where the temp mount
/// came from so `goUpWithinArchive` can walk back out to the outer archive and the breadcrumb can
/// show the full chain.
///
/// A nested mount is the extracted temp copy, so writing to it wouldn't reach the enclosing
/// archive; `isNestedArchive` keeps it read-only this pass (writing back through nesting is a
/// later item), matching how the app greys out unsupported ops (§M5 "capability degradation").
extension PanelViewController {
    /// The archive pane is browsing a nested mount (an archive-inside-an-archive extracted to
    /// temp), not a real on-disk archive — the gate that keeps its contents read-only.
    var isNestedArchive: Bool {
        guard let archivePath = panel.path.backend.archivePath else { return false }
        return host?.nestedArchiveRegistry.isNestedMount(archivePath) ?? false
    }

    /// A browsed archive that accepts writes — the gate for delete (F8), add-into (F5/F6), and
    /// paste-into. True for a top-level archive; false for a nested mount, whose bytes are an
    /// extracted temp copy, so an edit wouldn't propagate back into the enclosing archive
    /// (writing back through nesting is a later M4 pass). Distinct from the read-only `isArchive`,
    /// which still allows browsing, F5 copy-*out*, and Quick Look inside a nested archive.
    var isWritableArchive: Bool {
        isArchive && !isNestedArchive
    }

    /// The enclosing-archive chain of the current pane, outermost-first, for the path-bar
    /// breadcrumb — empty unless the pane is browsing a nested archive.
    func archiveBreadcrumbAncestry() -> [VFSPath] {
        guard let archivePath = panel.path.backend.archivePath else { return [] }
        return host?.nestedArchiveRegistry.ancestry(ofMountAt: archivePath) ?? []
    }

    /// The archive-root location for a nested archive extracted to `onDiskPath` — Enter navigates
    /// here after the member lands on disk. (The sibling `archiveRoot(for:)` maps a *local* archive
    /// file; a nested archive's on-disk path is the temp extraction, not the browsed entry's path.)
    func nestedArchiveRoot(atOnDiskPath onDiskPath: String) -> VFSPath {
        VFSPath(backend: .archive(forArchiveAt: onDiskPath), path: "/")
    }

    /// Browse into the archive member under the cursor: extract it to disk (off-main), register
    /// where it came from, and navigate into its virtual contents. Reuses a still-present prior
    /// extraction instead of re-spawning `bsdtar`. `entry` must be a browsable-archive *file*
    /// member of the pane's archive (the caller checks `ArchiveType.isBrowsable`).
    func beginNestedArchiveEntry(for entry: FileEntry) {
        guard let outerArchivePath = panel.path.backend.archivePath else { return }
        let origin = entry.path // the member's identity inside the outer archive

        // Re-entering an inner archive we already extracted this session reuses the temp file (and
        // its cached mount), matching how the preview cache avoids re-extracting the same member.
        if let existing = host?.nestedArchiveRegistry.reusableMount(forOrigin: origin) {
            navigate(to: nestedArchiveRoot(atOnDiskPath: existing))
            return
        }

        let innerPath = origin.path
        Task {
            do {
                let mountPath = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    let extraction = try ArchiveExtractor.extract(
                        innerPaths: [innerPath],
                        fromArchiveAt: outerArchivePath
                    )
                    // A single member extracts to exactly one location; `ArchiveExtractor` already
                    // threw if nothing landed, so this file exists.
                    return extraction.extractedPaths[0]
                }.value
                host?.nestedArchiveRegistry.record(mountOnDiskPath: mountPath, origin: origin)
                navigate(to: nestedArchiveRoot(atOnDiskPath: mountPath))
            } catch {
                presentOperationFailure(
                    message: String(localized: "Couldn’t open the nested archive"),
                    detail: describe(error)
                )
            }
        }
    }
}
