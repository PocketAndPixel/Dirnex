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
/// later item), matching how the app grays out unsupported ops (§M5 "capability degradation").
///
/// **An archive on a *server* is the same shape and shares the same registry** (PLAN.md §M24
/// Slice 6, at the bottom of this file): its mount is a temp copy of the whole file, so walking up
/// has to reach the server rather than the extraction, and writing to it would land in a temp file
/// rather than in the archive the user is looking at. `isNestedArchive` reads `true` for it and
/// means what it has always meant — *this mount's bytes are a copy of something that lives
/// elsewhere* — which is why widening it was the fix rather than a second gate beside it.
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

    /// The same question asked of one **row**: whether an edit to `entry`'s extracted copy could be
    /// written back into the archive it came from.
    ///
    /// The pane-keyed ``isWritableArchive`` is right for a browse and blind in a results tab, whose
    /// container is the synthetic `search:` path — so F4 on a hit inside a zip reported "Only files
    /// on this Mac can be edited", about a file the browse route edits perfectly well (PLAN.md §M22
    /// Slice 5). Same answer as `isWritableArchive` whenever the pane *is* the archive, since then
    /// the row's backend is the pane's.
    func isWritableArchiveMember(_ entry: FileEntry) -> Bool {
        guard let archivePath = entry.path.backend.archivePath else { return false }
        return !(host?.nestedArchiveRegistry.isNestedMount(archivePath) ?? false)
    }

    /// The enclosing-archive chain of the current pane, outermost-first, for the path-bar
    /// breadcrumb — empty unless the pane is browsing a nested archive.
    func archiveBreadcrumbAncestry() -> [VFSPath] {
        guard let archivePath = panel.path.backend.archivePath else { return [] }
        return host?.nestedArchiveRegistry.ancestry(ofMountAt: archivePath) ?? []
    }

    /// The archive-root location for a mount whose bytes are a **temp copy** at `onDiskPath` —
    /// Enter navigates here once the copy has landed.
    ///
    /// Two kinds reach it and neither has an on-disk path of its own: a nested archive, whose bytes
    /// are a member extracted from the enclosing one, and an archive on a server, whose bytes are
    /// the whole file downloaded (PLAN.md §M24 Slice 6). The sibling `archiveRoot(for:)` is the
    /// third case — a *local* archive file, which is already the path it is browsed from.
    func stagedArchiveRoot(atOnDiskPath onDiskPath: String) -> VFSPath {
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
            navigate(to: stagedArchiveRoot(atOnDiskPath: existing))
            return
        }

        let innerPath = origin.path
        // Enter is an explicit request for the member's bytes, so an encrypted outer archive asks
        // for its passphrase here — once per archive per session (PLAN.md §M19).
        withArchivePassphrase(forArchiveAt: outerArchivePath) { passphrase in
            try await BlockingWork.run { () -> Result<String, any Error> in
                Result {
                    let extraction = try ArchiveExtractor.extract(
                        innerPaths: [innerPath],
                        fromArchiveAt: outerArchivePath,
                        passphrase: passphrase
                    )
                    // A single member extracts to exactly one location; `ArchiveExtractor` already
                    // threw if nothing landed, so this file exists.
                    return extraction.extractedPaths[0]
                }
            }.get()
        } onSuccess: { [weak self] mountPath in
            guard let self else { return }
            host?.nestedArchiveRegistry.record(mountOnDiskPath: mountPath, origin: origin)
            navigate(to: stagedArchiveRoot(atOnDiskPath: mountPath))
        } onFailure: { [weak self] error in
            self?.presentOperationFailure(
                message: String(localized: "Couldn’t open the nested archive"),
                detail: self?.describe(error) ?? ""
            )
        }
    }
}

/// Browsing an archive that lives on a **server** (PLAN.md §M24 Slice 6).
///
/// `ArchiveBackend.init(archiveOnDiskPath:)` needs a real path, so there is exactly one shape
/// available: fetch the whole file, then mount the copy. That is the mirror of packing *to* a
/// server, which builds the whole archive here and then uploads it — and it is why ⏎ on a `.zip`
/// over SFTP is the one navigation in this app that has to say what it costs before it happens.
/// Everywhere else ⏎ on a folder-shaped row is free.
///
/// **It is recorded as a mount whose bytes are a temp copy**, which is exactly what a nested archive
/// is, so it reuses the registry above rather than growing a second one. Three things fall out of
/// that and all three are what is wanted: walking up at the archive root goes back to the *server's*
/// directory rather than to the extraction, the breadcrumb chain names the server, and the mount is
/// **read-only** — `isNestedArchive` is the gate F8, F5-into and paste already draw, and a write to
/// this copy would land in a temp file rather than in the archive on the server. Writing into one is
/// repack-then-upload, which the pack half of this slice makes reachable and which is its own pass.
extension PanelViewController {
    /// Whether ⏎ on `entry` means "browse into this archive that is not on this disk".
    ///
    /// Asked of the **row**, never of the pane, so a search hit browses exactly as a listed row
    /// does — the property four others in this app had to be corrected for (PLAN.md §M22 Slice 5).
    func remoteArchiveToBrowse(for entry: FileEntry) -> FileEntry? {
        guard entry.path.backend.isRemoteConnection, entry.kind == .file,
              ArchiveType.isBrowsable(entry.name) else { return nil }
        return entry
    }

    /// Fetch the whole archive, register where it came from, and browse into the copy.
    ///
    /// The confirmation is `MaterializationPlan`'s, through the same funnel every other M24 gesture
    /// uses — so a small archive opens with no dialog, a large one names its size once, and the
    /// bytes are reused by every later gesture over the same row. A second ⏎ on an archive already
    /// fetched this session costs nothing at all: the plan reads the copy as `cached` and the mount
    /// is the same file.
    func beginRemoteArchiveEntry(for entry: FileEntry) {
        materialize([entry], for: .browseArchive) {
            String(
                localized: "Couldn’t open this archive",
                comment: "Alert title when an archive on a server can't be downloaded to browse it."
            )
        } then: { [weak self] urls in
            guard let self, let url = urls.first else { return }
            host?.nestedArchiveRegistry.record(mountOnDiskPath: url.path, origin: entry.path)
            navigate(to: stagedArchiveRoot(atOnDiskPath: url.path))
        }
    }
}
