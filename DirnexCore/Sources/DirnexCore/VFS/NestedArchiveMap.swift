import Foundation

/// The provenance of nested-archive mounts within one window (PLAN.md §M4 "nested archives —
/// browse/extract a zip inside a zip").
///
/// A browsed archive is served by an `ArchiveBackend` whose id encodes the archive's *on-disk*
/// path. An archive nested inside another has no on-disk path of its own — its bytes live only
/// as a member of the outer archive — so entering it first extracts that member to a temp file,
/// then mounts *that* file. This map records, for each such temp mount, the inner member it came
/// from (its `VFSPath` inside the outer archive). Two things need that link:
///
/// - **Walking back out.** At a nested archive's root, "go up" must return to the *outer* archive's
///   inner directory (landing on the member we came from), not dump the user into the temp
///   extraction directory. `origin(ofMountOnDiskPath:)` is that anchor.
/// - **The breadcrumb.** `ancestry(ofMountOnDiskPath:)` walks the whole chain outermost-first so
///   the path bar can render `outer.zip ▸ sub ▸ inner.zip ▸ …` instead of a bare temp name.
///
/// It also lets a re-entry reuse an existing extraction (`mountOnDiskPath(forOrigin:)`) rather
/// than re-spawning `bsdtar`. Pure and `Sendable`: the app layer owns the FileManager side (the
/// extraction, and confirming a reused temp file still exists); all the wiring logic is here and
/// unit-tested.
public struct NestedArchiveMap: Sendable {
    /// temp mount on-disk path → the inner member `VFSPath` it was extracted from.
    private var originByMount: [String: VFSPath] = [:]
    /// inner member `VFSPath` → the temp mount on-disk path it was extracted to (the reuse index).
    private var mountByOrigin: [VFSPath: String] = [:]

    public init() {}

    /// Record that the archive member at `origin` was extracted to `mountOnDiskPath` and mounted.
    public mutating func record(mountOnDiskPath: String, origin: VFSPath) {
        originByMount[mountOnDiskPath] = origin
        mountByOrigin[origin] = mountOnDiskPath
    }

    /// The inner member a nested mount was extracted from — the anchor "go up" returns to (landing
    /// on that member) instead of the temp extraction directory. `nil` for a top-level archive
    /// opened straight from a local file, which has no recorded origin.
    public func origin(ofMountOnDiskPath path: String) -> VFSPath? {
        originByMount[path]
    }

    /// A temp mount already extracted for `origin`, so re-entering the same inner archive can reuse
    /// it instead of re-spawning `bsdtar`. `nil` if it was never entered; the caller still confirms
    /// the file is on disk (a session's temps can be cleared) before trusting it.
    public func mountOnDiskPath(forOrigin origin: VFSPath) -> String? {
        mountByOrigin[origin]
    }

    /// The chain of enclosing archive members from the outermost inward, ending with the member
    /// that produced this mount — outermost-first, exactly the order a breadcrumb renders. Each
    /// element is the member's `VFSPath` inside its own container archive, so its `backend`
    /// names the enclosing archive and its `path` the location within it. Empty for a top-level
    /// archive (no origin), so the breadcrumb falls back to the archive's own name.
    public func ancestry(ofMountOnDiskPath path: String) -> [VFSPath] {
        var chain: [VFSPath] = []
        var current = path
        // Bounded by the number of recorded mounts: each step moves to a strictly-outer archive.
        while let origin = originByMount[current] {
            chain.append(origin)
            guard let enclosingArchive = origin.backend.archivePath else { break }
            current = enclosingArchive
        }
        return chain.reversed()
    }
}
