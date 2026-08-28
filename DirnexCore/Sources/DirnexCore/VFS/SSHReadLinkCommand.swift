import Foundation

/// Builds the one shell command that reads a batch of symlink **targets** over an SSH exec channel,
/// because `sftp` cannot tell you what a link points at (PLAN.md §M25 Slice 4).
///
/// This is the third thing this project asks an SSH account to do, after §M22's subtree search and
/// §M23's segmented download, and it inherits both of their caveats: it runs the user's login shell,
/// and an account confined to the `sftp` subsystem refuses it. Every line was decided by a probe
/// against a real `sshd` on 2026-08-28.
///
/// ## Why a target has to be asked for at all
///
/// `sftp`'s batch `ls -la` prints no ` -> target` suffix, and `ls -la` **of the link itself follows
/// it** — reporting the target's mode and size, which is the same trap this repo records for
/// classifying an item before a recursive delete. So over SFTP alone a link's target is simply not
/// knowable, and `CopyEngine` recreates a link from `entry.symlinkDestination`: with nothing there
/// it would write `ln -s "" link`, which `symlink(2)` **accepts** on macOS (measured — it returns 0
/// and leaves a 0-byte dangling link). A copy that reports success and produces that is the quiet
/// failure this milestone exists to prevent, which is why an unreadable target is refused rather
/// than approximated.
///
/// ## Why `ls -ldn` and not `readlink`
///
/// `readlink` is the obvious verb and it loses on all three counts that matter, each measured:
///
/// - **It cannot be authenticated.** ``SFTPTransport/runCommand(_:isCancelled:)`` hands back stdout
///   and deliberately no exit status, and an `sftp`-only account answers an exec request with the
///   prose *"This service allows sftp connections only."* on **stdout**. A bare `readlink` reader
///   would take that sentence for a target and recreate the link pointing at it. An `ls -ldn` row
///   carries a mode field *and echoes the path that was asked about*, so prose cannot be mistaken
///   for an answer — the same sentinel rule ``SSHFindListingParser`` states for the walk.
/// - **It cannot be batched.** One exec costs **77 ms** against a loopback server and reading twelve
///   links in one costs **79 ms**, so the cost is the connection and a link-at-a-time read would
///   spend it per link. `readlink` with several arguments prints one line per *successful* one and
///   **silently skips the failures** (measured: three arguments, two lines), so a reader zipping
///   outputs to inputs attributes one link's target to a different link — a wrong answer where the
///   unbatched version merely has none. Every `ls -ldn` row names its own path, so correspondence is
///   carried in the data rather than in the order.
/// - **It cannot be framed.** Both tools print a raw target, so a target containing a newline breaks
///   the line-oriented reading either way — but an `ls` row carries the **size column**, which for a
///   symlink is the target's byte length, and that is what lets the parser take exactly the right
///   bytes (▸ ``ColumnarListing/linkTarget(in:targetLength:)``).
///
/// ## Why `/usr/bin/env`
///
/// An exec channel runs the user's login shell and sources their rc — measured here again, this
/// Mac's `.bashrc` printed an error on every command — so a shell function named `ls` would shadow
/// the binary. `/usr/bin/env` execs it from `PATH` with no shell lookup; if it is somehow absent the
/// command fails and the caller degrades to "target unknown", which is the safe direction.
public enum SSHReadLinkCommand {
    /// The most paths to name in one command.
    ///
    /// A cap is not optional: every path is spelled out in the server's `argv`, which is bounded
    /// (`ARG_MAX` is 1 MiB on this Mac and need not be on a server). At a generous 4 KiB per path
    /// 256 paths is ~1 MiB of argv in the worst case and a few kilobytes in every real one, and
    /// since the cost measured is the *connection* rather than the row count, a directory holding
    /// more links than this pays one extra exec per batch rather than one per link.
    public static let defaultBatchLimit = 256

    /// `ls -ldn` the given paths, printing one row each.
    ///
    /// `-l` for the long row that carries the mode, the size and the ` -> target`; `-d` so a link to
    /// a *directory* prints the link rather than the directory's contents; `-n` so the owner and
    /// group are numeric, sparing the server a passwd lookup per row that nothing here reads.
    /// `LC_ALL=C` for a stable date column, matching the walk. `--` so a path can never be read as a
    /// flag — verified accepted by this BSD `ls`.
    ///
    /// A path that is missing, or is not a link, does **not** stop the others: probed with three
    /// paths of which one did not exist, the other two printed normally. A non-link prints a row
    /// whose mode is not `l`, which is how "this is not a link" stays distinguishable from "no
    /// answer came back".
    public static func targets(of paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        let operands = paths.map(SSHShellQuote.quote).joined(separator: " ")
        return "/usr/bin/env LC_ALL=C ls -ldn -- \(operands)"
    }

    /// The paths split into batches no larger than ``defaultBatchLimit``, in their original order.
    public static func batches(
        of paths: [String],
        limit: Int = defaultBatchLimit
    ) -> [[String]] {
        guard limit > 0 else { return paths.isEmpty ? [] : [paths] }
        return stride(from: 0, to: paths.count, by: limit).map {
            Array(paths[$0..<min($0 + limit, paths.count)])
        }
    }
}
