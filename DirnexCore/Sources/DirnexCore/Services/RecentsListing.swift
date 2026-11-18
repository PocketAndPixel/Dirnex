import Foundation

/// One file Recents found, and when it was last opened.
public struct RecentsHit: Sendable, Equatable {
    /// The absolute path, as `mdfind` printed it.
    public let path: String
    /// When the file was last opened, or `nil` where `mdfind` printed `(null)`. The query asks for a
    /// date inside its window, so a hit without one is not expected; it is kept rather than dropped,
    /// and sorts as the oldest.
    public let lastUsed: Date?

    public init(path: String, lastUsed: Date?) {
        self.path = path
        self.lastUsed = lastUsed
    }
}

extension RecentsQuery {
    /// The hits in what `mdfind -0 -attr kMDItemLastUsedDate` printed (``mdfindArguments()``).
    ///
    /// Probed 2026-11-18: each record is the path, then `   kMDItemLastUsedDate = ` and the date,
    /// then a NUL. The date reads `2026-11-17 18:40:34 +0000`, in whole seconds and always in UTC,
    /// whatever `TZ`, `LANG` or `LC_ALL` the tool runs under, or `(null)` for a file with none.
    ///
    /// Two shapes a name can take decide the parse:
    /// - **A name may hold the separator itself**, and `mdfind` does not escape it: a file named
    ///   `fake   kMDItemLastUsedDate = 2001-01-01 00:00:00 +0000.txt` printed that text and then its
    ///   real date. The tool appends the attribute after the path, so the **last** separator is the
    ///   real one.
    /// - **A name may hold a newline**, which is why the records are NUL-terminated; split on
    ///   newlines, `line\nbreak.txt` was two paths, neither of them a file.
    ///
    /// A record that is not valid UTF-8 is dropped alone rather than costing the whole answer
    /// (``SubprocessText`` says why); such a path could not be statted anyway. A record with no
    /// separator keeps its whole text as the path, with no date.
    public static func hits(fromOutput data: Data) -> [RecentsHit] {
        let separator = "   \(lastUsedAttribute) = "
        let formatter = lastUsedDateFormatter()
        return data.split(separator: 0, omittingEmptySubsequences: true).compactMap { record in
            guard let text = String(bytes: record, encoding: .utf8) else { return nil }
            guard let split = text.range(of: separator, options: .backwards) else {
                return RecentsHit(path: text, lastUsed: nil)
            }
            return RecentsHit(
                path: String(text[..<split.lowerBound]),
                lastUsed: formatter.date(from: String(text[split.upperBound...]))
            )
        }
    }

    /// Reads `2026-11-17 18:40:34 +0000`, and nothing else: `(null)` answers `nil`. Made per parse
    /// rather than shared, since a `DateFormatter` is not `Sendable`, and one parse is one `mdfind`.
    private static func lastUsedDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }
}

/// What Recents lists: the newest hits, each statted and carrying its last-opened date (PLAN.md §M40
/// Slice 2).
///
/// The cap is a rendering budget, as for every `mdfind`-backed listing, and the dates are what make
/// it fair. `mdfind` prints paths in no useful order, so when only the paths came back, a cap kept an
/// arbitrary N of them; with each hit's date in hand, the N kept are the N most recently opened.
public struct RecentsListing: Sendable, Equatable {
    /// The rows, newest first, each with ``FileEntry/lastUsedDate`` set.
    public let entries: [FileEntry]
    /// Whether more hits were found than `limit` kept.
    public let truncated: Bool

    /// The newest `limit` of `hits`, statted through `stat`.
    ///
    /// `stat` answers the entry at a path, or `nil` for a file that has gone since the index saw it,
    /// which is skipped. It is the app's `VFSBackend.stat`, injected so this stays pure. Ties in date
    /// go by path, so the cut is the same every time.
    public init(hits: [RecentsHit], limit: Int, stat: (String) -> FileEntry?) {
        let newest = hits.sorted { lhs, rhs in
            let lhsDate = lhs.lastUsed ?? .distantPast
            let rhsDate = rhs.lastUsed ?? .distantPast
            return lhsDate == rhsDate ? lhs.path < rhs.path : lhsDate > rhsDate
        }
        let kept = newest.prefix(max(limit, 0))
        entries = kept.compactMap { hit in stat(hit.path)?.withLastUsedDate(hit.lastUsed) }
        truncated = hits.count > kept.count
    }
}
