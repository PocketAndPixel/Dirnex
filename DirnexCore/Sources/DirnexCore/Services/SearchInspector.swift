import Foundation

/// What a walk reads off a file beyond its listing row: the Finder tags it carries and the text
/// inside it (PLAN.md §M40 Slice 3).
///
/// A listing hands over a name, a size, a date and a kind, and a walk over a server can answer only
/// those (``SearchFields/listed``). On this Mac a folder Spotlight does not index is walked too, and
/// there the file itself is at hand, so the two clauses the index used to answer alone can be read
/// directly. Held by ``SearchPredicate``, which asks it only after the listing's clauses have passed,
/// since each answer here is a read of the file.
public protocol SearchInspector: Sendable {
    /// The fields this answers on top of a listing's.
    var fields: SearchFields { get }

    /// The names of the Finder tags on `entry`, in any case; `[]` when it carries none, and when
    /// they cannot be read.
    func tagNames(of entry: FileEntry) -> [String]

    /// Whether `entry`'s text holds `needle`, case- and diacritic-insensitively. Asked of files only.
    /// `isCancelled` is polled while a long file is read.
    func text(of entry: FileEntry, contains needle: String, isCancelled: () -> Bool) -> Bool
}

/// Reads a file on this Mac: its tags from their extended attribute, its text from its bytes.
public struct LocalSearchInspector: SearchInspector {
    public init() {}

    public var fields: SearchFields {
        [.tags, .content]
    }

    /// The tags as the pane's Tags column reads them (`FinderTagStorage`), so a hit agrees with the
    /// column it is drawn in, a symlink's included.
    public func tagNames(of entry: FileEntry) -> [String] {
        ((try? FinderTagStorage.tags(at: entry.path)) ?? []).map(\.name)
    }

    /// Never reads a file whose bytes are not on this disk: a read is what makes a cloud provider
    /// download it (``FileEntry/isDataless``), and a search would pull a whole cloud folder down.
    public func text(
        of entry: FileEntry,
        contains needle: String,
        isCancelled: () -> Bool
    ) -> Bool {
        guard entry.path.backend == .local, !entry.isDataless else { return false }
        return TextContentSearch.file(
            at: entry.path.path,
            contains: needle,
            isCancelled: isCancelled
        )
    }
}
