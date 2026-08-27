import Foundation

/// Reads what ``SSHFindCommand/subtree(root:rowLimit:)`` prints — `find … -exec ls -ldn {} +` over a
/// whole tree — into rows a backend can turn into `FileEntry`s (PLAN.md §M22 Slice 4).
///
/// The lexing is `sftp`'s and FTP's, already shared in ``ColumnarListing``: nine columns and then a
/// name kept verbatim, an `@`/`+` mode suffix tolerated, a ` -> target` suffix split off a symlink.
/// What is this parser's own is the two rules below, and both exist because the output arrives over
/// a channel that is *not* only carrying the listing.
///
/// ## The root row is the sentinel
///
/// An exec channel is shared with the user's login shell, so anything that shell prints lands in the
/// same stream — and an account restricted to the `sftp` subsystem answers an exec request with the
/// sentence "This service allows sftp connections only." on **stdout**, exit 1, stderr empty
/// (measured). There is nothing in an exit code to key on either: `find` exits 1 while returning
/// perfectly good rows when one subdirectory was unreadable (also measured). So the proof that the
/// command ran is the command's own first output — `find` always prints the operand it was given —
/// and its absence is what makes this return `nil`, meaning "walk instead" rather than "empty
/// folder". An empty folder still produces that one row, which is exactly the case the two answers
/// have to be told apart on.
///
/// ## Every path is anchored under the root
///
/// A row is kept only if its name field starts with the root the command asked about. That rejects
/// the shell's own noise for free, and it is also the guard on the one thing about `ls` that could
/// not be measured here: GNU `ls` quotes names carrying odd characters when its output is a
/// terminal, and is documented to print them literally when it is a pipe — which is what this is,
/// but there is no Linux host to confirm it on. If it ever quotes, the path stops matching the
/// anchor and the search falls back to the walk, which is slower and right, instead of rendering a
/// row whose name has acquired quotes.
enum SSHFindListingParser {
    /// One entry as the server described it — the same fields ``SFTPListingParser/Entry`` carries,
    /// but named by **full remote path** rather than by leaf, because that is what a search result
    /// needs and what `find` prints.
    struct Row: Equatable {
        let path: String
        let kind: FileEntry.Kind
        let byteSize: Int64
        let modificationDate: Date
        let permissions: UInt16
        /// Owner and group as printed — **numeric** here, because the walk runs `ls -ldn` to avoid a
        /// passwd lookup per row. Text either way; see ``FileEntry/ownerName``.
        let ownerName: String
        let groupName: String
        let symlinkDestination: String?
    }

    /// A parsed run: the entries beneath the root, and how many rows the server actually printed.
    struct Listing: Equatable {
        /// Every row *under* `root`, in the server's own order. The root's own row is not among
        /// them — a folder is never a hit inside itself, the same rule ``SubtreeSearch`` applies to
        /// the walk.
        let rows: [Row]
        /// Rows printed, including the root's. The caller compares this with the row cap it asked
        /// for to decide whether the output was cut off; counting *parsed* rows rather than lines
        /// keeps a stray line of shell noise from reading as a row that was never there.
        let rowCount: Int
    }

    /// Parse `text` as the output of a find rooted at `root`, or `nil` when it does not look like
    /// that output at all — see the sentinel rule above.
    ///
    /// `root` must already be ``SSHFindCommand/normalizedRoot(_:)``, since it is compared against
    /// what the server echoed back.
    static func parse(_ text: String, under root: String) -> Listing? {
        let formatters = ColumnarListing.unixDateFormatters()
        // A root of "/" would otherwise demand paths beginning "//".
        let childPrefix = root == "/" ? "/" : root + "/"
        var rows: [Row] = []
        var rowCount = 0
        var sawRoot = false

        for line in text.split(whereSeparator: \.isNewline) {
            guard let row = ColumnarListing.unixRow(line, formatters: formatters) else { continue }
            if row.name == root {
                sawRoot = true
                rowCount += 1
                continue
            }
            guard row.name.hasPrefix(childPrefix) else { continue }
            rowCount += 1
            rows.append(Row(
                path: row.name,
                kind: row.kind,
                byteSize: row.byteSize,
                modificationDate: row.modificationDate,
                permissions: row.permissions,
                ownerName: row.ownerName,
                groupName: row.groupName,
                symlinkDestination: row.symlinkDestination
            ))
        }

        return sawRoot ? Listing(rows: rows, rowCount: rowCount) : nil
    }
}
