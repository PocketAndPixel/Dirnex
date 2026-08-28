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

    /// One class's execute column, and the special bit `ls(1)` overlays onto the same character.
    private struct SpecialBitSlot {
        let index: Int
        let execute: UInt16
        let flag: UInt16
    }

    /// Map the 9 permission characters (`rwxr-xr-x`) to a full `mode & 0o7777` word, `s`/`S`/`t`/`T`
    /// included.
    ///
    /// The three execute positions are overloaded by `ls(1)`: `s` is set-uid *and* execute, `S` is
    /// set-uid *without* it, and the other class spells the sticky bit `t`/`T` the same way. Reading
    /// any of the four as a plain execute bit was harmless while this fed nothing but a row that does
    /// not draw permissions; Get Info draws them, and a `rwsr-xr-x` binary rendered `rwxr-xr-x` is a
    /// panel quietly disclaiming the one bit anybody inspects a remote binary *for*.
    ///
    /// ``POSIXPermissions`` already stores and renders all twelve bits, so being exact here costs a
    /// lookup table and buys back a fact rather than an approximation.
    static func permissions(fromMode modeField: Substring) -> UInt16 {
        let characters = Array(modeField)
        guard characters.count >= 10 else { return 0 }
        let weights: [UInt16] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        var bits: UInt16 = 0
        for (offset, weight) in weights.enumerated() where characters[offset + 1] != "-" {
            bits |= weight
        }
        // The execute column of each class, and the special bit its glyph also stands for. A struct
        // rather than a 3-tuple, which SwiftLint's `large_tuple` forbids.
        let special = [
            SpecialBitSlot(index: 3, execute: 0o100, flag: 0o4000),
            SpecialBitSlot(index: 6, execute: 0o010, flag: 0o2000),
            SpecialBitSlot(index: 9, execute: 0o001, flag: 0o1000)
        ]
        for slot in special {
            switch characters[slot.index] {
            case "s", "t": bits |= slot.flag | slot.execute
            case "S", "T": bits |= slot.flag; bits &= ~slot.execute
            default: break
            }
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
    ///
    /// **The anchor is truncated to the minute, and that is what makes a parse repeatable.**
    /// `defaultDate` supplies *every* component the format does not name — not just the year it is
    /// here for — and `MMM d HH:mm` names no **seconds**. A bare `Date()` therefore stamped each
    /// parse with the second and millisecond it happened to run at, so parsing one unchanged `ls`
    /// row twice produced two dates up to a minute apart. Nothing in a listing shows it: the column
    /// is drawn to the minute and sorting is unaffected. What it broke is every comparison of two
    /// readings of the same file — `RemoteFileRevision` has only size and date to work with on SFTP
    /// and FTP, so a remote write-back compared the listing's date against the pre-upload `stat`'s
    /// and told the user **"someone else has edited it"** on every save (measured live against a
    /// real server 2026-08-22: 36 bytes both sides, dates 39 s apart). S3 never saw it — it carries
    /// an entity tag, which settles the comparison before the date is consulted.
    static func formatters(for formats: [String]) -> [DateFormatter] {
        let anchor = yearAnchor()
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if !format.contains("y") { formatter.defaultDate = anchor }
            return formatter
        }
    }

    /// Now, truncated to the minute — a `defaultDate` that can only ever contribute the **year**.
    ///
    /// Every finer component a year-less format leaves unnamed (second, nanosecond) reads zero from
    /// this, and every coarser one it *does* name (month, day, hour, minute) is overwritten by the
    /// stamp being parsed — so two parses of one row agree for as long as the year does, which is
    /// the whole claim. The year boundary is already handled downstream by ``date(from:formatters:)``
    /// rolling a clearly-future result back.
    private static func yearAnchor() -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        return calendar.date(from: parts) ?? now
    }

    /// The formatters for the Unix `ls -l` time column, which is a recent entry's `HH:mm` or an
    /// older one's year. All three dialects print the identical column, in English regardless of
    /// locale, and each held its own verbatim copy of this list before it was named here.
    static func unixDateFormatters() -> [DateFormatter] {
        formatters(for: ["MMM d HH:mm", "MMM d yyyy", "MMM d HH:mm:ss"])
    }

    /// Parse `string` with the first formatter that accepts it, or ``FileEntry/unknownDate`` when
    /// none does — so a stamp in a shape nobody anticipated draws a dash rather than year 1.
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
        return FileEntry.unknownDate
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
        /// Columns 2 and 3 — the owner and group **as the source spelled them**, verbatim.
        ///
        /// Read as text and never as an id, because that is what the column is: `sftp` and FTP's
        /// Unix dialect print a name (`oleg     staff`), while `bsdtar -tvf` prints a name for a tar
        /// and a bare number for a zip, which stores no owner names. Nothing in the row distinguishes
        /// the two, and neither spelling means anything on this Mac — see ``FileEntry/ownerName``.
        ///
        /// They were read and dropped on the floor until M24 Slice 7, which is why every remote
        /// `FileEntry` carried `ownerID == 0`: the information had been arriving in the same line as
        /// the mode all along and only the struct stopped short of it.
        let ownerName: String
        let groupName: String
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
    /// `splitsLinkTarget` is what a dialect that **never prints a target** turns off, and it is not a
    /// tidiness switch: ` -> ` is four ordinary characters a *name* may contain, so in such a dialect
    /// every arrow belongs to the name and splitting at one lists the link under a shorter one — a
    /// wrong file name, which a copy then writes. `sftp`'s batch `ls -la` is that dialect (measured
    /// against OpenSSH 10.2: a plain link prints no target at all), and the size column cannot
    /// rescue it, because the coincidence is exact — a link named `a -> b` has size 1 and a 1-byte
    /// trailing `b`.
    ///
    /// `ArchiveTOCParser` deliberately does **not** come through here. `bsdtar -tvf` prints the same
    /// shape, but that parser accepts any first column rather than requiring a mode field, and reads
    /// an unrecognized mode as a file where these two read it as `.other` — a difference in what a
    /// line means, not in how it is lexed, so folding it in would change which archives parse.
    static func unixRow(
        _ line: Substring,
        formatters: [DateFormatter],
        splitsLinkTarget: Bool = true
    ) -> UnixRow? {
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        guard columns.count >= 9, isModeField(columns[0]), let modeChar = columns[0].first,
              var name = nameField(in: line, afterColumns: 8) else { return nil }

        let byteSize = Int64(columns[4]) ?? 0

        var symlinkDestination: String?
        if splitsLinkTarget, modeChar == "l",
           let split = linkTarget(in: name, targetLength: byteSize) {
            symlinkDestination = split.target
            name = split.name
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
            byteSize: byteSize,
            modificationDate: date(
                from: "\(columns[5]) \(columns[6]) \(columns[7])", formatters: formatters
            ),
            permissions: permissions(fromMode: columns[0]),
            ownerName: String(columns[2]),
            groupName: String(columns[3]),
            name: name,
            symlinkDestination: symlinkDestination
        )
    }

    /// Split a symlink row's name field into the link's own name and the target it points at,
    /// using the **size column** — which for a symlink is the byte length of its target — to decide
    /// which ` -> ` is the separator.
    ///
    /// A bare "split at the first ` -> `" is what shipped until M25 Slice 4, and it is wrong in both
    /// directions because ` -> ` is four perfectly ordinary characters that a *name* and a *target*
    /// may each contain. Measured against a real server on 2026-08-28: a link named `a -> b` that
    /// points at `c` prints `… 1 …/a -> b -> c`, where the first-arrow reading answers `b -> c` —
    /// a plausible wrong target, which for a copy means recreating the link pointing somewhere the
    /// user never wrote. The size column settles it with no guessing: `1` can only be `c`.
    ///
    /// So the rule is *the separator whose suffix is exactly the size column's many bytes*, taken
    /// left to right. It was checked against nine adversarial targets on that run — two containing
    /// newlines, one a tab, one a trailing space, one containing ` -> ` and one ending in it — and
    /// the column equalled the target's true byte length in every case, which is POSIX's definition
    /// of a symlink's size rather than a habit of one `ls`.
    ///
    /// When no separator satisfies the size — a server whose dialect reports something else in that
    /// column, or a target the line-oriented reader has already cut short at an embedded newline —
    /// this falls back to the first arrow, which is exactly what shipped before. That keeps the rule
    /// strictly additive: it can sharpen a target, never lose one that used to parse.
    ///
    /// Returns `nil` when the field carries no ` -> ` at all, which is every non-symlink row and a
    /// symlink row from a dialect that prints no target (`sftp`'s own `ls -la`, notably).
    static func linkTarget(in field: String, targetLength: Int64) -> (name: String, target: String)? {
        var searched = field.startIndex..<field.endIndex
        var first: (name: String, target: String)?
        while let separator = field.range(of: " -> ", range: searched) {
            let candidate = field[separator.upperBound...]
            let split = (name: String(field[..<separator.lowerBound]), target: String(candidate))
            if first == nil { first = split }
            if Int64(candidate.utf8.count) == targetLength { return split }
            searched = separator.upperBound..<field.endIndex
        }
        return first
    }
}
