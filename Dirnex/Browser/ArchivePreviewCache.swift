import DirnexCore
import Foundation

/// One archive member, identified by the archive's on-disk path and the member's inner path —
/// the cache key for a previewed archive entry (PLAN.md §M4 "Quick Look inside").
struct ArchiveMember: Hashable {
    let archivePath: String
    let innerPath: String
}

/// Caches archive members that have been extracted to disk so they can be previewed by Quick
/// Look (⌘Y) or the embedded Quick View (⌃Q) — the read-only companion to F5 copy-out
/// (PLAN.md §M4 "Quick Look inside" / "copy out with F5").
///
/// A preview needs a real file, but an archive member lives only inside the archive; so the
/// first time the cursor lands on a member we extract that single member with `bsdtar`
/// (`ArchiveExtractor`) and remember where it landed. Arrowing back onto the same member reuses
/// the extracted copy instead of re-spawning `bsdtar`, and — because each member keeps its own
/// slot — a slow extraction that finishes after the cursor has moved on can't evict the member
/// now under the cursor. One cache per window (`BrowserWindowController`), shared by both panes
/// and both preview surfaces.
///
/// Extracted files accumulate under `ArchiveExtractor`'s temp root and are purged at launch, so
/// the cache never deletes anything itself — the session's previews are reclaimed next launch or
/// by the OS clearing its temp directory, exactly like F5's extractions.
@MainActor
final class ArchivePreviewCache {
    private var extracted: [ArchiveMember: URL] = [:]

    /// The extracted on-disk URL for `member` if it has already been extracted this session,
    /// else `nil` — a synchronous lookup the preview surfaces use to resolve the file to show.
    func cachedURL(for member: ArchiveMember) -> URL? {
        extracted[member]
    }

    /// Extract `member` to disk (off-main via `bsdtar`) and cache it, returning its on-disk URL.
    /// Reuses the cached copy when the same member is requested again. Throws when extraction
    /// fails (a damaged or missing member) — the caller then simply leaves it unpreviewable.
    func extractedURL(for member: ArchiveMember) async throws -> URL {
        if let url = extracted[member] { return url }
        let url = try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let extraction = try ArchiveExtractor.extract(
                innerPaths: [member.innerPath],
                fromArchiveAt: member.archivePath
            )
            // A single member extracts to exactly one location; `ArchiveExtractor` already threw
            // if nothing landed, so this file exists.
            return URL(fileURLWithPath: extraction.extractedPaths[0])
        }.value
        extracted[member] = url
        return url
    }
}
