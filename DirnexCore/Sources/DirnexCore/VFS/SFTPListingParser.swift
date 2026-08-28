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
/// - Symlink **targets are not shown** (no ` -> target`), so `symlinkDestination` is always `nil`
///   here — the target comes from the SSH exec channel instead (``SSHReadLinkCommand``), and where
///   there is none the copy refuses rather than guessing (PLAN.md §M25 Slice 4).
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
        /// Owner and group as the *server* spelled them — see ``FileEntry/ownerName``.
        let ownerName: String
        let groupName: String
        let symlinkDestination: String?
    }

    /// Parse a raw `ls -la` block into its rows (names reduced to a last path component), in the
    /// server's order, **including** any `.`/`..` rows — the caller decides what to keep.
    static func parse(_ text: String) -> [Entry] {
        let formatters = ColumnarListing.unixDateFormatters()
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let entry = parseLine(line, formatters: formatters) { entries.append(entry) }
        }
        return entries
    }

    // MARK: - Line scanning

    /// `sftp`'s one departure from the shared row shape: a name arrives as a **full path**, so both
    /// it and a symlink target are reduced to a last component. Everything else about the row —
    /// the columns, the ` -> ` split, the `sftp>` prompt echo and error lines the guards reject —
    /// is `ColumnarListing.unixRow`'s.
    private static func parseLine(_ line: Substring, formatters: [DateFormatter]) -> Entry? {
        // **No ` -> ` split in this dialect**, which is a correctness rule and not a shortcut.
        // `sftp`'s `ls -la` provably never prints a target (re-measured 2026-08-28 against OpenSSH
        // 10.2), so every arrow it emits is part of a *name* — and splitting at one listed a link
        // named `a -> b` under the name `a`, which a copy then writes to disk. The split used to be
        // kept "for compatibility with a plain shell `ls -la`", output this parser is never handed:
        // `SFTPTransport.listDirectory` is documented as the batch client's own. Nothing is lost,
        // because a target that a listing cannot carry is exactly what the exec channel supplies.
        guard let row = ColumnarListing.unixRow(
            line, formatters: formatters, splitsLinkTarget: false
        ) else { return nil }
        return Entry(
            name: lastComponent(of: row.name),
            kind: row.kind,
            byteSize: row.byteSize,
            modificationDate: row.modificationDate,
            permissions: row.permissions,
            ownerName: row.ownerName,
            groupName: row.groupName,
            // Always `nil` — see the rule above; the field stays on `Entry` because the backend's
            // shared construction reads it and the exec channel fills it in later.
            symlinkDestination: row.symlinkDestination
        )
    }

    /// The last path component of a possibly-full path (`/home/oleg/notes.txt` → `notes.txt`,
    /// `notes.txt` → `notes.txt`, `/home/oleg/.` → `.`). Falls back to the input when it is all
    /// slashes (can't arise from a real listing).
    private static func lastComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }
}
