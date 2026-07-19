import DirnexCore
import Foundation

/// Tracks nested-archive mounts for one window (PLAN.md §M4 "nested archives — browse/extract a
/// zip inside a zip"), the app-layer companion to the pure `NestedArchiveMap`.
///
/// An archive nested inside another is entered by extracting its member to a temp file (via
/// `ArchiveExtractor`, like Quick Look inside and F5 copy-out) and mounting *that* file. This
/// registry remembers where each such temp mount came from so the pane can walk back out to the
/// outer archive (`origin(ofMountAt:)`), render the full breadcrumb chain (`ancestry(ofMountAt:)`),
/// and reuse a prior extraction instead of re-spawning `bsdtar` (`reusableMount(forOrigin:)`).
///
/// One registry per window (`BrowserWindowController`), shared by both panes — mirroring
/// `ArchivePreviewCache`. The wiring logic lives in the tested `NestedArchiveMap`; this only owns
/// the FileManager side (recording, and confirming a reused temp file still exists on disk).
@MainActor
final class NestedArchiveRegistry {
    private var map = NestedArchiveMap()

    /// Record that the inner archive member at `origin` was extracted to `mountOnDiskPath`.
    func record(mountOnDiskPath: String, origin: VFSPath) {
        map.record(mountOnDiskPath: mountOnDiskPath, origin: origin)
    }

    /// The inner member a nested mount came from — the anchor "go up" returns to instead of the
    /// temp extraction directory. `nil` for a top-level archive opened from a local file.
    func origin(ofMountAt archiveOnDiskPath: String) -> VFSPath? {
        map.origin(ofMountOnDiskPath: archiveOnDiskPath)
    }

    /// Whether the archive at `archiveOnDiskPath` is a nested mount (extracted to temp) rather than
    /// a real on-disk archive — the gate that keeps a nested archive read-only, since a write to the
    /// temp copy wouldn't propagate back into the enclosing archive.
    func isNestedMount(_ archiveOnDiskPath: String) -> Bool {
        map.origin(ofMountOnDiskPath: archiveOnDiskPath) != nil
    }

    /// The chain of enclosing archive members outermost-first, for the breadcrumb. Empty for a
    /// top-level archive.
    func ancestry(ofMountAt archiveOnDiskPath: String) -> [VFSPath] {
        map.ancestry(ofMountOnDiskPath: archiveOnDiskPath)
    }

    /// A temp file already extracted for `origin` and still on disk, so re-entering the same inner
    /// archive skips a fresh `bsdtar` extraction. `nil` if never entered or the temp was cleared.
    func reusableMount(forOrigin origin: VFSPath) -> String? {
        guard let path = map.mountOnDiskPath(forOrigin: origin),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }
}
