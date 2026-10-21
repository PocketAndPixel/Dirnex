import Foundation

/// Parses the table an FTP server sends in reply to `LIST` into flat directory entries.
///
/// A cousin of `SFTPListingParser` and `ArchiveTOCParser` — same "fixed columns, then a name" shape
/// — but `LIST` output is **not** standardized, so this handles the two dialects that cover
/// essentially every server in the field:
///
/// **Unix** (verified against real captured bytes, 2026-07-25):
///
///     -rw------- 1 sa users          6 Jul 25 20:55 .hidden
///     -rw------- 1 sa users    3145728 Jul 25 20:53 big.bin
///     drwx------ 2 sa users          0 Jul 25 20:55 sub dir
///
/// **DOS / IIS**, the other common form:
///
///     04-27-00  09:09PM       <DIR>          licensed
///     02-21-00  10:57AM              1173 readme.txt
///
/// Three differences from `sftp`'s dialect matter, all confirmed on the wire:
/// - Names come back **bare**, not as full paths, so nothing is reduced to a last component. A name
///   is taken verbatim after the last fixed column, which keeps internal spaces (`sub dir`).
/// - There are **no `.` / `..` rows**, so a directory cannot be stat'd through its own listing the
///   way `SFTPBackend` does it — `FTPBackend` reads an item's stat out of its *parent's* listing.
/// - Symlink targets **are** printed (` -> target`), unlike `sftp`'s `ls`.
///
/// A `LIST` stamp is the server's wall clock with no zone, so it is read in the zone the user set for
/// the server (``parse(_:timeZone:)``) — this Mac's own unless they said otherwise. Where the server
/// also answers `MLSD`, its exact UTC times replace these (``applyingFacts(_:to:)``); the rows stay
/// this parser's either way, for the reason ``FTPFactsParser`` gives.
enum FTPListingParser {
    /// One parsed row: everything the backend needs to build a `FileEntry` for a remote item.
    struct Entry: Equatable {
        let name: String
        let kind: FileEntry.Kind
        let byteSize: Int64
        /// **Approximate when it came from `LIST`.** That stamp carries no year for recent files,
        /// no seconds *and* no time zone, and it is the server's wall clock — so it is only as right
        /// as the zone it was read in (``parse(_:timeZone:)``), and near a year boundary it can be a
        /// year out. It is good enough to display and to sort by; it is not good enough to compare
        /// two files with, which is why `DirectorySync` must not compare an FTP side by
        /// `.sizeAndDate`. `MLSD`'s `modify` fact is exact, and replaces it where the server sends
        /// one (``applyingFacts(_:to:)``).
        let modificationDate: Date
        /// The mode, or `nil` from the DOS/IIS dialect, which prints none.
        let permissions: UInt16?
        /// Owner and group as the *server* spelled them, `nil` in the DOS dialect, which has no such
        /// columns — see ``FileEntry/ownerName``.
        let ownerName: String?
        let groupName: String?
        let symlinkDestination: String?

        /// The same row, last modified at `date`.
        func with(modificationDate date: Date) -> Entry {
            Entry(
                name: name,
                kind: kind,
                byteSize: byteSize,
                modificationDate: date,
                permissions: permissions,
                ownerName: ownerName,
                groupName: groupName,
                symlinkDestination: symlinkDestination
            )
        }
    }

    /// Parse a raw `LIST` block into its rows, in the server's order. Lines that match neither
    /// dialect — a multiline banner, a `total 12` header, a blank line — are skipped rather than
    /// guessed at.
    ///
    /// `timeZone` is the server's clock, which the stamps are written on. `nil` reads them as this
    /// Mac's own, which is what every FTP listing did before a server could be given a zone.
    static func parse(_ text: String, timeZone: TimeZone? = nil) -> [Entry] {
        let unix = ColumnarListing.unixDateFormatters(timeZone: timeZone)
        let dos = dosDateFormatters(timeZone: timeZone)
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))[...]
            guard let entry = parseUnixLine(trimmed, formatters: unix)
                ?? parseDOSLine(trimmed, formatters: dos) else { continue }
            // `.` and `..` are not sent by any server observed, but a rogue one costs nothing to
            // guard against — they would otherwise appear as navigable rows inside themselves.
            guard entry.name != ".", entry.name != ".." else { continue }
            entries.append(entry)
        }
        return entries
    }

    /// `entries` with each row's time replaced by `MLSD`'s exact one, where the two listings agree
    /// on what the row **is**.
    ///
    /// The agreement test is what keeps a followed symlink from lending its target's time to the
    /// link: a server that follows links reports `linkdir` as a `dir`, and that `modify` is the
    /// folder's rather than the link's. Where the kinds differ the row keeps its `LIST` stamp, and a
    /// fact whose kind this parser could not read vetoes nothing. A row `MLSD` did not mention, or
    /// gave no time for, keeps its `LIST` stamp too.
    static func applyingFacts(_ facts: [FTPFactsParser.Entry], to entries: [Entry]) -> [Entry] {
        var byName: [String: FTPFactsParser.Entry] = [:]
        for fact in facts where byName[fact.name] == nil {
            byName[fact.name] = fact
        }
        return entries.map { entry in
            guard let fact = byName[entry.name], let date = fact.modificationDate,
                  fact.kind == nil || fact.kind == entry.kind else { return entry }
            return entry.with(modificationDate: date)
        }
    }

    // MARK: - Unix dialect

    /// The Unix dialect *is* the shared row, name and symlink target included — unlike `sftp`, an
    /// FTP server prints both bare, so there is nothing left to reduce.
    private static func parseUnixLine(_ line: Substring, formatters: [DateFormatter]) -> Entry? {
        guard let row = ColumnarListing.unixRow(line, formatters: formatters) else { return nil }
        return Entry(
            name: row.name,
            kind: row.kind,
            byteSize: row.byteSize,
            modificationDate: row.modificationDate,
            permissions: row.permissions,
            ownerName: row.ownerName,
            groupName: row.groupName,
            symlinkDestination: row.symlinkDestination
        )
    }

    // MARK: - DOS / IIS dialect

    /// `04-27-00  09:09PM       <DIR>          licensed` — date, time, then either the `<DIR>`
    /// marker or a byte count, then the name verbatim.
    private static func parseDOSLine(_ line: Substring, formatters: [DateFormatter]) -> Entry? {
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        guard columns.count >= 4, looksLikeDOSDate(columns[0]),
              let name = ColumnarListing.nameField(in: line, afterColumns: 3) else { return nil }

        let isDirectory = columns[2].uppercased() == "<DIR>"
        guard isDirectory || Int64(columns[2]) != nil else { return nil }

        return Entry(
            name: name,
            kind: isDirectory ? .directory : .file,
            byteSize: isDirectory ? 0 : (Int64(columns[2]) ?? 0),
            modificationDate: ColumnarListing.date(
                from: "\(columns[0]) \(columns[1])", formatters: formatters
            ),
            // A DOS listing reports no mode, no owner and no group — the columns do not exist. This
            // used to answer `0o755`/`0o644` "rather than 0, which would render every remote row as
            // unreadable in the permissions column"; there is no permissions column, so the invented
            // value reached nothing until Get Info, which would have drawn it as the server's own.
            permissions: nil,
            ownerName: nil,
            groupName: nil,
            symlinkDestination: nil
        )
    }

    /// `MM-dd-yy` or `MM-dd-yyyy`: two or four digits, two hyphens, digits throughout.
    private static func looksLikeDOSDate(_ field: Substring) -> Bool {
        let parts = field.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    // MARK: - Dates

    /// The DOS dialect's own stamps. The Unix ones come from `ColumnarListing.unixDateFormatters`,
    /// which every dialect shares; these are FTP's alone, and the only two-digit-year formats
    /// anywhere — which is why the year test there is `contains("y")` and not `contains("yyyy")`.
    private static func dosDateFormatters(timeZone: TimeZone?) -> [DateFormatter] {
        ColumnarListing.formatters(
            for: ["MM-dd-yy hh:mma", "MM-dd-yyyy hh:mma", "MM-dd-yy HH:mm", "MM-dd-yyyy HH:mm"],
            timeZone: timeZone
        )
    }
}
