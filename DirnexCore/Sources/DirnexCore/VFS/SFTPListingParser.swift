import Foundation

/// Parses the `ls -l`-style table `sftp`'s batch `ls -la` prints into flat directory entries. It is
/// a cousin of `ArchiveTOCParser` — same "fixed columns, then a name" shape — but tuned to `sftp`'s
/// dialect, which differs from GNU `ls -l` in ways that matter (verified against a live server):
///
///     drwxr-xr-x    ? oleg     staff         192 Jul 13 00:09 /home/oleg/docs/.
///     -rw-r--r--    ? oleg     staff          11 Jul 13 00:09 /home/oleg/docs/notes.txt
///     lrwxr-xr-x    ? oleg     staff           9 Jul 13 00:09 /home/oleg/docs/latest
///
/// - The link-count column is `?` (`sftp` doesn't report it) — harmless, it isn't used.
/// - Names are printed as **full paths** (because `ls -la <abs>` echoes the argument), so every
///   name is reduced to its last path component. A POSIX name can't contain `/`, so this is exact.
/// - Symlink **targets are not shown** (no ` -> target`), so `symlinkDestination` is `nil`; the
///   ` -> ` split is still handled for compatibility with a plain `ls -la` over a shell.
/// - The `.`/`..` self and parent rows are **kept** here; `SFTPBackend` drops them when listing but
///   uses the `.` row (the directory's own stat) to stat a directory.
enum SFTPListingParser {
    /// One parsed row: everything the backend needs to build a `FileEntry` for a remote item.
    struct Entry: Equatable {
        let name: String
        let kind: FileEntry.Kind
        let byteSize: Int64
        let modificationDate: Date
        let permissions: UInt16
        let symlinkDestination: String?
    }

    /// Parse a raw `ls -la` block into its rows (names reduced to a last path component), in the
    /// server's order, **including** any `.`/`..` rows — the caller decides what to keep.
    static func parse(_ text: String) -> [Entry] {
        let formatters = dateFormatters()
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let entry = parseLine(line, formatters: formatters) { entries.append(entry) }
        }
        return entries
    }

    // MARK: - Line scanning

    private static func parseLine(_ line: Substring, formatters: [DateFormatter]) -> Entry? {
        // The leading columns never contain spaces, so a collapsing split reads them; the name is
        // taken verbatim after the 8th column to keep internal spaces (`my report.txt`). The
        // interactive `sftp>` prompt echo and error lines have too few / non-mode columns and are
        // skipped by the count + mode-field guards.
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        guard columns.count >= 9, isModeField(columns[0]),
              let modeChar = columns[0].first,
              var rawName = nameField(in: line, afterColumns: 8) else { return nil }

        let byteSize = Int64(columns[4]) ?? 0
        let date = parseDate(columns[5], columns[6], columns[7], formatters: formatters)
        let permissions = parsePermissions(columns[0])

        var symlinkDestination: String?
        if modeChar == "l", let range = rawName.range(of: " -> ") {
            symlinkDestination = lastComponent(of: String(rawName[range.upperBound...]))
            rawName = String(rawName[..<range.lowerBound])
        }
        let name = lastComponent(of: rawName)

        let kind: FileEntry.Kind
        switch modeChar {
        case "d": kind = .directory
        case "l": kind = .symlink
        case "-": kind = .file
        default: kind = .other // block/char device, socket, FIFO — shown but not navigable
        }

        return Entry(
            name: name,
            kind: kind,
            byteSize: byteSize,
            modificationDate: date,
            permissions: permissions,
            symlinkDestination: symlinkDestination
        )
    }

    /// The last path component of a possibly-full path (`/home/oleg/notes.txt` → `notes.txt`,
    /// `notes.txt` → `notes.txt`, `/home/oleg/.` → `.`). Falls back to the input when it is all
    /// slashes (can't arise from a real listing).
    private static func lastComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    /// Whether a first column looks like a `ls` mode string — 10 permission characters, or 11 when
    /// the server appends an ACL `+` or an xattr `@`. Rejects the `sftp>` prompt echo and stray
    /// lines.
    private static func isModeField(_ field: Substring) -> Bool {
        guard field.count == 10 || field.count == 11, let first = field.first else { return false }
        return "-dlbcsp".contains(first)
    }

    /// The substring of `line` after skipping `count` whitespace-delimited columns — the entry
    /// name, kept verbatim so internal spaces survive. Mirrors `ArchiveTOCParser.nameField`.
    private static func nameField(in line: Substring, afterColumns count: Int) -> String? {
        var index = line.startIndex
        var seen = 0
        while seen < count {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            guard index < line.endIndex else { return nil }
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
            seen += 1
        }
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        guard index < line.endIndex else { return nil }
        return String(line[index...])
    }

    /// Map the 9 permission characters (`rwxr-xr-x`) to POSIX mode bits. `s`/`S`/`t`/`T` (setuid,
    /// setgid, sticky) are treated as a set bit — permissions here are cosmetic (row display), not
    /// enforced, so the approximation is harmless.
    private static func parsePermissions(_ modeField: Substring) -> UInt16 {
        let characters = Array(modeField)
        guard characters.count >= 10 else { return 0 }
        let weights: [UInt16] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        var bits: UInt16 = 0
        for (offset, weight) in weights.enumerated() where characters[offset + 1] != "-" {
            bits |= weight
        }
        return bits
    }

    // MARK: - Dates

    private static func dateFormatters() -> [DateFormatter] {
        // `ls` prints a recent entry as "MMM d HH:mm" (no year — the *current* year is implied) and
        // an older one as "MMM d yyyy". A `DateFormatter` fills a missing year from `defaultDate`,
        // which defaults to a 2000 reference — so the no-year formats must default to *now*, or a
        // recent file would wrongly show the year 2000. The year-stamped format keeps its own year.
        let now = Date()
        return ["MMM d HH:mm", "MMM d yyyy", "MMM d HH:mm:ss"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if !format.contains("yyyy") { formatter.defaultDate = now }
            return formatter
        }
    }

    private static func parseDate(
        _ month: Substring,
        _ day: Substring,
        _ timeOrYear: Substring,
        formatters: [DateFormatter]
    ) -> Date {
        let string = "\(month) \(day) \(timeOrYear)"
        for formatter in formatters {
            if let date = formatter.date(from: string) { return rollBackIfFuture(date) }
        }
        return .distantPast
    }

    /// A no-year date assigned the current year can land in the future near a year boundary (a
    /// "Dec 30 12:00" entry read on Jan 2 means *last* December). `ls` would then have shown a
    /// year, but defensively roll a clearly-future date back one year.
    private static func rollBackIfFuture(_ date: Date) -> Date {
        guard date.timeIntervalSinceNow > 24 * 60 * 60 else { return date }
        return Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: date) ?? date
    }
}
