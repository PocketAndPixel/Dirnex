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
    /// Where an *encrypted* archive's one whole-archive extraction landed. libarchive reads
    /// sequentially and has no member filter, so extracting one member decrypts and writes them
    /// all; without this, arrowing through five members of a 600 MB archive would do that five
    /// times, on a keystroke. Keyed by archive, so each is paid for exactly once per session.
    private var wholeArchiveExtractions: [String: URL] = [:]

    /// The extracted on-disk URL for `member` if it has already been extracted this session,
    /// else `nil` — a synchronous lookup the preview surfaces use to resolve the file to show.
    func cachedURL(for member: ArchiveMember) -> URL? {
        extracted[member]
    }

    /// Extract `member` to disk (off-main) and cache it, returning its on-disk URL. Reuses the
    /// cached copy when the same member is requested again, and — for an encrypted archive — the
    /// sibling members that came out of the same extraction.
    ///
    /// `passphrase` is required for an encrypted archive and ignored otherwise, so a caller holding
    /// one may pass it speculatively; without one, an encrypted archive throws
    /// ``EncryptedArchiveError/passphraseRequired`` rather than reaching `bsdtar`, whose interactive
    /// prompt cannot be answered from here at all (see `ArchiveExtractor.extract`). Throws too when
    /// extraction fails, and the caller then leaves the member unpreviewable.
    func extractedURL(
        for member: ArchiveMember,
        passphrase: ArchivePassphrase? = nil
    ) async throws -> URL {
        if let url = extracted[member] { return url }
        if let url = wholeArchiveURL(for: member) {
            extracted[member] = url
            return url
        }
        let extraction = try await Task.detached(priority: .userInitiated) {
            () throws -> ArchiveExtractor.Extraction in
            try ArchiveExtractor.extract(
                innerPaths: [member.innerPath],
                fromArchiveAt: member.archivePath,
                passphrase: passphrase
            )
        }.value
        if extraction.isWholeArchive {
            wholeArchiveExtractions[member.archivePath] = extraction.directory
        }
        // A single member extracts to exactly one location; `ArchiveExtractor` already threw if
        // nothing landed, so this file exists.
        let url = URL(fileURLWithPath: extraction.extractedPaths[0])
        extracted[member] = url
        return url
    }

    /// `member`'s file inside its archive's earlier whole-archive extraction, if there was one and
    /// the file is still there. Checked before spawning anything, and `nil` when the extraction has
    /// since been cleared out of the temp directory — in which case the ordinary route re-does it.
    private func wholeArchiveURL(for member: ArchiveMember) -> URL? {
        guard let directory = wholeArchiveExtractions[member.archivePath] else { return nil }
        let path = ArchiveExtraction.extractedLocation(
            ofInnerPath: member.innerPath, inDirectory: directory.path
        )
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
