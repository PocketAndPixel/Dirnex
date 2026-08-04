import Foundation

/// The scanning primitives shared by every listing that arrives as **fixed columns followed by a
/// name**: `sftp`'s batch `ls -la` (`SFTPListingParser`), FTP's `LIST` in both its Unix and DOS
/// dialects (`FTPListingParser`), and `bsdtar -tvf`'s table of contents (`ArchiveTOCParser`).
///
/// Three different external tools print three different dialects, but the *lexing* underneath is one
/// problem — skip N whitespace-delimited columns, keep the rest verbatim — and the date handling has
/// one trap that all three fall into. They were three verbatim copies until this file; the copies had
/// already begun to drift (see ``formatters(for:)``), which is the argument for having it.
enum ColumnarListing {
    // MARK: - Names

    /// The substring of `line` after skipping `count` whitespace-delimited columns — the entry name,
    /// kept **verbatim** so internal spaces survive.
    ///
    /// A collapsing `split` cannot do this: it would mangle `a file with spaces.txt` into fragments,
    /// and a name is the one field of these listings that is not column-shaped.
    static func nameField(in line: Substring, afterColumns count: Int) -> String? {
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

    // MARK: - The mode column

    /// Whether a first column looks like an `ls` mode string — 10 permission characters, or 11 when
    /// the server appends an ACL `+` or an xattr `@`. Rejects the interactive `sftp>` prompt echo,
    /// FTP's `total 8` header and any stray line.
    static func isModeField(_ field: Substring) -> Bool {
        guard field.count == 10 || field.count == 11, let first = field.first else { return false }
        return "-dlbcsp".contains(first)
    }

    /// Map the 9 permission characters (`rwxr-xr-x`) to POSIX mode bits. `s`/`S`/`t`/`T` (setuid,
    /// setgid, sticky) are treated as a set bit — permissions from a remote listing are cosmetic
    /// (row display), never enforced, so the approximation is harmless.
    static func permissions(fromMode modeField: Substring) -> UInt16 {
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

    /// Build the formatters for `formats`, defaulting a **year-less** format's year to *now*.
    ///
    /// This is the trap all three dialects share (docs/NOTES.md records it for `bsdtar`): each tool
    /// prints a recent entry with no year (`MMM d HH:mm`) and an older one with one (`MMM d yyyy`),
    /// and a `DateFormatter` fills a missing year from `defaultDate` — which defaults to a **2000**
    /// reference. Without this, every recently-modified remote file reads as the year 2000.
    ///
    /// The year test is `contains("y")`, not `contains("yyyy")`: FTP's DOS dialect has two-digit-year
    /// formats (`MM-dd-yy hh:mma`) that carry a year and must not be given one. The three copies this
    /// replaces had drifted on exactly this point — two spelled it `"yyyy"` and only the FTP one
    /// `"y"` — which was harmless only because the `yy` formats lived solely in the FTP copy.
    static func formatters(for formats: [String]) -> [DateFormatter] {
        let now = Date()
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if !format.contains("y") { formatter.defaultDate = now }
            return formatter
        }
    }

    /// The formatters for the Unix `ls -l` time column, which is a recent entry's `HH:mm` or an
    /// older one's year. All three dialects print the identical column, in English regardless of
    /// locale, and each held its own verbatim copy of this list before it was named here.
    static func unixDateFormatters() -> [DateFormatter] {
        formatters(for: ["MMM d HH:mm", "MMM d yyyy", "MMM d HH:mm:ss"])
    }

    /// Parse `string` with the first formatter that accepts it, or `.distantPast` when none does.
    ///
    /// A no-year date assigned the current year can land in the future near a year boundary (a
    /// "Dec 30 12:00" entry read on Jan 2 means *last* December), so a clearly-future result is
    /// rolled back a year. The day of slack also absorbs a server clock running ahead of ours, which
    /// a zone-less stamp makes likely rather than exotic.
    static func date(from string: String, formatters: [DateFormatter]) -> Date {
        for formatter in formatters {
            guard let date = formatter.date(from: string) else { continue }
            guard date.timeIntervalSinceNow > 24 * 60 * 60 else { return date }
            return Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: date) ?? date
        }
        return .distantPast
    }

    // MARK: - The Unix `ls -l` row

    /// One row of a Unix `ls -l`-style listing, taken as far as the shared lexing goes: the fields
    /// are read and any ` -> target` suffix is split off, but the name is left **raw**, because what
    /// a name means is the one thing the two dialects disagree on — `sftp` prints full paths where
    /// FTP prints bare ones.
    struct UnixRow: Equatable {
        let kind: FileEntry.Kind
        let byteSize: Int64
        let modificationDate: Date
        let permissions: UInt16
        /// The name field with any ` -> target` suffix removed, otherwise verbatim.
        let name: String
        /// The symlink target as printed, or `nil` for anything not a symlink carrying one.
        let symlinkDestination: String?
    }

    /// Scan one `mode links owner group size month day time-or-year name` row, or `nil` for a line
    /// that is not one.
    ///
    /// `sftp`'s batch `ls -la` and FTP's Unix-dialect `LIST` print the same nine columns, so this is
    /// the whole of what both parsers do before applying their own naming rule. The leading columns
    /// never contain spaces, so a collapsing split reads them; the name is taken verbatim after the
    /// 8th, which is what keeps `my report.txt` in one piece.
    ///
    /// The count and mode-field guards are what reject every line that is not a row: the interactive
    /// `sftp>` prompt echo, `sftp`'s error text, and FTP's `total 8` header.
    ///
    /// `ArchiveTOCParser` deliberately does **not** come through here. `bsdtar -tvf` prints the same
    /// shape, but that parser accepts any first column rather than requiring a mode field, and reads
    /// an unrecognized mode as a file where these two read it as `.other` — a difference in what a
    /// line means, not in how it is lexed, so folding it in would change which archives parse.
    static func unixRow(_ line: Substring, formatters: [DateFormatter]) -> UnixRow? {
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        guard columns.count >= 9, isModeField(columns[0]), let modeChar = columns[0].first,
              var name = nameField(in: line, afterColumns: 8) else { return nil }

        var symlinkDestination: String?
        if modeChar == "l", let range = name.range(of: " -> ") {
            symlinkDestination = String(name[range.upperBound...])
            name = String(name[..<range.lowerBound])
        }

        let kind: FileEntry.Kind
        switch modeChar {
        case "d": kind = .directory
        case "l": kind = .symlink
        case "-": kind = .file
        default: kind = .other // block/char device, socket, FIFO — shown but not navigable
        }

        return UnixRow(
            kind: kind,
            byteSize: Int64(columns[4]) ?? 0,
            modificationDate: date(
                from: "\(columns[5]) \(columns[6]) \(columns[7])", formatters: formatters
            ),
            permissions: permissions(fromMode: columns[0]),
            name: name,
            symlinkDestination: symlinkDestination
        )
    }
}
