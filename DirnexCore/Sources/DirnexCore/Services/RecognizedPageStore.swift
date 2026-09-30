import Foundation

/// What a document's pages were read as, kept for as long as the app runs and no longer
/// (2026-09-19).
///
/// Recognizing a scanned page costs ~0.2–0.5 s and a book costs the better part of a minute
/// (measured), so a reader who arrows off a scan and back onto it must not pay twice. Pages are
/// stamped with the file's identity rather than its path, for the reason ``ArchiveIdentity`` was
/// written: a path that now names different bytes would otherwise be answered with the old
/// document's text, which is the quiet direction — a plausible page of text belonging to a file
/// that is gone.
///
/// **In memory, never on disk, and that is a decision rather than an omission.** What this holds is
/// the *contents* of the user's documents. A store on disk would put the text of anything ever
/// previewed — a document inside a locked vault included — under Application Support, where it
/// would outlive the lock; ``VaultPrivacy`` exists because the app's own stores, not the system's
/// caches, were what remembered a vault's file names. So the price of a relaunch is paying again,
/// and nothing of a document survives the process that read it.
///
/// Absent means *not read yet*, never *this page has nothing on it* — a miss costs the time to read
/// the page again and can never cost a wrong answer, which is what makes an eviction policy that
/// cannot see what is on screen safe here.
public struct RecognizedPageStore: Sendable {
    /// How many pages are kept across every document before the least recently used document is
    /// dropped whole. Three books' worth: a page is a few kilobytes of text and word outlines.
    public static let defaultPageLimit = 500

    private struct Entry {
        var pages: [Int: RecognizedPageText]
        var used: Int
    }

    private let pageLimit: Int
    private var documents: [ArchiveIdentity: Entry] = [:]
    private var clock = 0

    public init(pageLimit: Int = RecognizedPageStore.defaultPageLimit) {
        self.pageLimit = max(1, pageLimit)
    }

    /// How many pages are held, across every document.
    public var count: Int {
        documents.values.reduce(0) { $0 + $1.pages.count }
    }

    /// Everything read for `identity` so far, by page index. Empty for a document nothing has been
    /// read for.
    public func pages(for identity: ArchiveIdentity) -> [Int: RecognizedPageText] {
        documents[identity]?.pages ?? [:]
    }

    /// Keep what reading page `index` of `identity` found, evicting whole documents — least
    /// recently used first — until the store is inside its limit again.
    ///
    /// Whole documents, because a document is read and searched as a unit: half a book's pages
    /// would cost a second reading of the other half anyway, and leave the store holding pages
    /// nothing will ask for.
    public mutating func store(
        _ page: RecognizedPageText,
        at index: Int,
        for identity: ArchiveIdentity
    ) {
        clock += 1
        var entry = documents[identity] ?? Entry(pages: [:], used: clock)
        entry.pages[index] = page
        entry.used = clock
        documents[identity] = entry
        evictWhileOverLimit(keeping: identity)
    }

    /// Note that `identity` is being read from, so a document the reader has come back to is not
    /// the next one dropped.
    public mutating func touch(_ identity: ArchiveIdentity) {
        guard documents[identity] != nil else { return }
        clock += 1
        documents[identity]?.used = clock
    }

    // MARK: - Private

    private mutating func evictWhileOverLimit(keeping identity: ArchiveIdentity) {
        while count > pageLimit {
            // The document being read is never the one dropped: dropping it would put the store in
            // a loop, reading pages it throws away as it reads them.
            let oldest = documents
                .filter { $0.key != identity }
                .min { $0.value.used < $1.value.used }
            guard let oldest else { return }
            documents.removeValue(forKey: oldest.key)
        }
    }
}
