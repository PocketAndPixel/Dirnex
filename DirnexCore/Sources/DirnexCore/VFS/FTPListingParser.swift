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
/// `MLSD` would supply an exact, zone-anchored timestamp and remove all of this guessing, but the
/// transport cannot send it: `curl` speaks only `LIST` and `NLST`. So FTP mtimes are approximate by
/// construction — see ``Entry/modificationDate``.
enum FTPListingParser {
    /// One parsed row: everything the backend needs to build a `FileEntry` for a remote item.
    struct Entry: Equatable {
        let name: String
        let kind: FileEntry.Kind
        let byteSize: Int64
        /// **Approximate.** A `LIST` stamp carries no year for recent files *and* no time zone, and
        /// it is the server's wall clock — so this can be off by the offset between the two
        /// machines, and near a year boundary by a year. It is good enough to display and to sort
        /// by; it is not good enough to compare two files with, which is why `DirectorySync` must
        /// not compare an FTP side by `.sizeAndDate`. An exact value needs a per-file `MDTM`.
        let modificationDate: Date
        let permissions: UInt16
        let symlinkDestination: String?
    }

    /// Parse a raw `LIST` block into its rows, in the server's order. Lines that match neither
    /// dialect — a multiline banner, a `total 12` header, a blank line — are skipped rather than
    /// guessed at.
    static func parse(_ text: String) -> [Entry] {
        let unix = unixDateFormatters()
        let dos = dosDateFormatters()
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

    // MARK: - Unix dialect

    private static func parseUnixLine(_ line: Substring, formatters: [DateFormatter]) -> Entry? {
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        guard columns.count >= 9, ColumnarListing.isModeField(columns[0]),
              let modeChar = columns[0].first,
              var rawName = ColumnarListing.nameField(in: line, afterColumns: 8) else { return nil }

        let byteSize = Int64(columns[4]) ?? 0
        let date = ColumnarListing.date(
            from: "\(columns[5]) \(columns[6]) \(columns[7])", formatters: formatters
        )

        var symlinkDestination: String?
        if modeChar == "l", let range = rawName.range(of: " -> ") {
            symlinkDestination = String(rawName[range.upperBound...])
            rawName = String(rawName[..<range.lowerBound])
        }

        let kind: FileEntry.Kind
        switch modeChar {
        case "d": kind = .directory
        case "l": kind = .symlink
        case "-": kind = .file
        default: kind = .other // block/char device, socket, FIFO — shown but not navigable
        }

        return Entry(
            name: rawName,
            kind: kind,
            byteSize: byteSize,
            modificationDate: date,
            permissions: ColumnarListing.permissions(fromMode: columns[0]),
            symlinkDestination: symlinkDestination
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
            // A DOS listing reports no mode at all. Report a plausible default rather than 0, which
            // would render every remote row as unreadable in the permissions column.
            permissions: isDirectory ? 0o755 : 0o644,
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

    private static func unixDateFormatters() -> [DateFormatter] {
        ColumnarListing.formatters(for: ["MMM d HH:mm", "MMM d yyyy", "MMM d HH:mm:ss"])
    }

    private static func dosDateFormatters() -> [DateFormatter] {
        ColumnarListing.formatters(
            for: ["MM-dd-yy hh:mma", "MM-dd-yyyy hh:mma", "MM-dd-yy HH:mm", "MM-dd-yyyy HH:mm"]
        )
    }
}
