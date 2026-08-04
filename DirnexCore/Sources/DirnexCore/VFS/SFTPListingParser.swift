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
        guard columns.count >= 9, ColumnarListing.isModeField(columns[0]),
              let modeChar = columns[0].first,
              var rawName = ColumnarListing.nameField(in: line, afterColumns: 8) else { return nil }

        let byteSize = Int64(columns[4]) ?? 0
        let date = ColumnarListing.date(
            from: "\(columns[5]) \(columns[6]) \(columns[7])", formatters: formatters
        )
        let permissions = ColumnarListing.permissions(fromMode: columns[0])

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

    // MARK: - Dates

    private static func dateFormatters() -> [DateFormatter] {
        ColumnarListing.formatters(for: ["MMM d HH:mm", "MMM d yyyy", "MMM d HH:mm:ss"])
    }
}
