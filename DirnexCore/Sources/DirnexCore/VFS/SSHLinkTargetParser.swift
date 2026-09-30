import Foundation

/// Reads what ``SSHReadLinkCommand/targets(of:)`` prints — one `ls -ldn` row per path — into the
/// targets of the links among them (PLAN.md §M25 Slice 4).
///
/// It answers a *dictionary* rather than a list because the command's whole point is that the
/// correspondence travels in the data: every row names the path it describes, so a batch survives
/// rows arriving in another order, rows missing entirely, and rows that turn out not to be links.
///
/// ## Three ways a path can have no target, and only one of them is a failure
///
/// - **Its row says it is not a link** (mode not `l`). A fact about the path, not about the server.
/// - **No row came back for it.** It is gone, or unreadable — again about the path.
/// - **The whole answer is not an answer.** An `sftp`-only account replies to an exec request with
///   prose on stdout (measured: *"This service allows sftp connections only."*), and
///   ``SFTPTransport/runCommand(_:isCancelled:)`` hands back no exit status to tell that apart. So
///   the sentinel is that a row must **echo a path that was asked about** and carry a mode field;
///   prose satisfies neither, and an answer with no recognised row at all is reported as `nil`.
///
/// A caller cannot act on the difference between the first two — both mean "this connection cannot
/// tell me" — but `nil` is worth separating because it is the one that says the *account* has no
/// exec channel, which is what a per-connection latch records.
///
/// ## Why a target is verified against the size column and dropped when it does not match
///
/// The size column of a symlink row is the target's byte length (POSIX's definition of a symlink's
/// size), and ``ColumnarListing/linkTarget(in:targetLength:)`` uses it to pick the right ` -> `.
/// This parser additionally *requires* the match, which the shared lexer deliberately does not:
/// the lexer must keep parsing FTP dialects whose size column may mean something else, while here a
/// target that cannot be verified is one that would be **recreated as a real link somewhere the
/// user never wrote**.
///
/// The case that makes it concrete was measured rather than imagined: a target containing a newline
/// is cut in half by any line-oriented read, so `weird\nname.txt` arrives as `weird`, and the size
/// column (14 against 5) is the only thing that knows. Refusing it leaves the copy to say the target
/// is unreadable, which is the honest answer and the one this milestone chose everywhere else.
enum SSHLinkTargetParser {
    /// The targets of whichever of `paths` came back as links, or `nil` when the output does not
    /// look like this command's at all.
    ///
    /// `paths` must be spelled exactly as they were sent, since they are compared against what the
    /// server echoed.
    static func parse(_ text: String, forPaths paths: [String]) -> [String: String]? {
        let requested = Set(paths)
        let formatters = ColumnarListing.unixDateFormatters()
        var targets: [String: String] = [:]
        var sawRow = false

        for line in text.split(whereSeparator: \.isNewline) {
            guard let row = ColumnarListing.unixRow(line, formatters: formatters),
                  requested.contains(row.name) else { continue }
            sawRow = true
            guard row.kind == .symlink,
                  let target = row.symlinkDestination,
                  Int64(target.utf8.count) == row.byteSize else { continue }
            targets[row.name] = target
        }

        return sawRow ? targets : nil
    }
}
