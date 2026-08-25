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
    /// Which archive each cached extraction came out of, so a path that has since been given a
    /// different archive drops its entries instead of previewing bytes that are no longer in it.
    private var identities: [String: ArchiveIdentity] = [:]

    /// The extracted on-disk URL for `member` if it has already been extracted this session,
    /// else `nil` — a synchronous lookup the preview surfaces use to resolve the file to show.
    func cachedURL(for member: ArchiveMember) -> URL? {
        dropExtractionsIfReplaced(archivePath: member.archivePath)
        return extracted[member]
    }

    /// Forget everything extracted from `archivePath` when the file there is not the archive those
    /// extractions came out of — deleting an archive and packing a new one under the same name is
    /// the ordinary way to redo one, and the entries left behind would otherwise show the previous
    /// archive's contents under the new archive's members. Worse than the stale *listing* the same
    /// replacement causes in `CompositeBackend`, because here the user is looking at file bytes.
    ///
    /// One `stat` per cursor movement over an archive member, which is the same order as the
    /// listing already costs and far below the extraction it guards.
    private func dropExtractionsIfReplaced(archivePath: String) {
        let identity = ArchiveIdentity.current(ofFileAt: archivePath)
        guard identities[archivePath] != identity else { return }
        identities[archivePath] = identity
        extracted = extracted.filter { $0.key.archivePath != archivePath }
    }

    /// Extract `member` to disk (off-main) and cache it, returning its on-disk URL. Reuses the
    /// cached copy when the same member is requested again.
    ///
    /// It used to keep a second cache beside this one, holding where an *encrypted* archive's
    /// whole-archive extraction landed, because the reader had no member filter and extracting one
    /// member decrypted them all — so the sibling members were free once anyone had paid for the
    /// first. ``DirnexCore/ArchiveMemberFilter`` retired it: one member of a 600 MB archive now
    /// costs 0.001 s rather than 1.48 s, so there is nothing left to amortize and arrowing through
    /// five members pays five times almost nothing instead of once for all of it.
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
        dropExtractionsIfReplaced(archivePath: member.archivePath)
        if let url = extracted[member] { return url }
        let extraction = try await BlockingWork.run {
            Result {
                try ArchiveExtractor.extract(
                    innerPaths: [member.innerPath],
                    fromArchiveAt: member.archivePath,
                    passphrase: passphrase
                )
            }
        }.get()
        // A single member extracts to exactly one location; `ArchiveExtractor` already threw if
        // nothing landed, so this file exists.
        let url = URL(fileURLWithPath: extraction.extractedPaths[0])
        extracted[member] = url
        return url
    }
}
