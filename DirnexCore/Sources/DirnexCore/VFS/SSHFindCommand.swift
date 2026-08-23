import Foundation

/// Builds the one shell command an SFTP account's search sends over an SSH **exec** channel, so the
/// server walks its own tree instead of answering a round trip per directory (PLAN.md §M22 Slice 4).
///
/// Every line of it was decided by a probe against a real `sshd` on 2026-08-16, and each carries the
/// measurement that put it there rather than a preference.
///
/// ## Why it is worth a second channel at all
///
/// The shipped walk opens a **new `sftp` connection per directory** — a full TCP connect, SSH
/// handshake and authentication each time. Measured over 501 directories on *loopback*, where there
/// is no network latency to blame: 34.3 s as separate connections (68.5 ms each) against **98 ms**
/// for one exec running this command. On a real server every one of those handshakes is several
/// round trips, so the gap only widens.
///
/// ## Why not GNU `find -printf`
///
/// The obvious spelling is `find … -printf '%y\t%s\t%T@\t%p\0'`: exact epoch seconds, NUL framing,
/// no locale surface. It is also GNU-only, which makes "the server's `find` is not GNU's" a failure
/// mode needing its own probe, its own fallback and a second parser — and none of it was verifiable
/// here, since there is no Linux host and no GNU coreutils on this Mac. `-exec ls -ldn {} +` is
/// POSIX on both halves, so that failure mode simply does not exist, and it prints the same
/// `ls -l` row ``ColumnarListing/unixRow(_:formatters:)`` already reads for `sftp` and FTP. The
/// price is paid in the date column and is named at ``SSHFindListingParser``.
///
/// ## Why `/usr/bin/env`
///
/// An exec channel runs the user's **login shell**, which sources their rc — measured: this Mac's
/// `.bashrc` ran, errors and all, on every `ssh host <command>`. A `find` shell *function* defined
/// there shadows the binary, and it does (probed: a function printed `SHADOWED` where the real
/// `find` would have listed). `/usr/bin/env` execs the binary from `PATH` with no shell lookup, so
/// it cannot be shadowed; if it is somehow absent the command exits 127 and the caller degrades to
/// the walk, which is the safe direction. Only the words the *shell* resolves need it — the `ls`
/// inside `-exec` is spawned by `find` itself and is out of reach of any function.
public enum SSHFindCommand {
    /// The most rows the server may print before the output is cut off.
    ///
    /// A cap is not optional: this is one command whose entire output is read into memory, and a
    /// `find` over a home directory can print hundreds of megabytes. At the ~170 bytes a row
    /// measured on the probe's long paths, 50 000 rows is ~8 MB — enough that no ordinary folder
    /// ever meets it, small enough that a mistake costs a pane rather than the process. Being cut
    /// off is reported through ``VFSSubtreeListing/isComplete``, never swallowed.
    public static let defaultRowLimit = 50_000

    /// `find` the whole subtree under `root`, printing one `ls -l` row per entry, capped at
    /// `rowLimit` rows.
    ///
    /// `head` is what applies the cap, and it applies it **on the server**: the alternative is
    /// reading an unbounded stream and dropping the tail here, which pays for every byte first.
    /// Probed — `find … | head -n 10` exits 0 with exactly 10 rows, so `find` dies of its `SIGPIPE`
    /// quietly rather than turning the cap into an error.
    public static func subtree(root: String, rowLimit: Int = defaultRowLimit) -> String {
        // `-exec ls -ldn {} +` batches as many paths per `ls` as the server's argv allows, so a big
        // tree costs a handful of spawns rather than one per entry. `-d` keeps `ls` from *listing*
        // each directory it is handed (which would duplicate every row `find` already produced), and
        // `-n` prints numeric owner and group — nothing here reads them, and resolving names costs
        // the server a passwd lookup per row.
        let find = "/usr/bin/env LC_ALL=C find \(quote(normalizedRoot(root))) -exec ls -ldn {} +"
        return "\(find) | /usr/bin/env head -n \(rowLimit)"
    }

    /// The root as the command should name it, which is also the prefix every returned path is
    /// checked against.
    ///
    /// `find` echoes the operand it was given verbatim at the head of every path it prints, so a
    /// trailing slash or a doubled separator would put the parser's anchor and the server's output
    /// permanently out of step. Trailing slashes matter for a second reason: `find dir/` **follows**
    /// a symlinked root on BSD, where `find dir` reports the link itself. `/` is the one root that
    /// keeps its slash, since it has nothing else to be.
    static func normalizedRoot(_ root: String) -> String {
        var trimmed = Substring(root)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return trimmed.isEmpty ? "/" : String(trimmed)
    }

    /// POSIX single-quoting, shared with the segmented download's own command — see
    /// ``SSHShellQuote``, which carries the rule and what was probed against a real server.
    static func quote(_ value: String) -> String {
        SSHShellQuote.quote(value)
    }
}
