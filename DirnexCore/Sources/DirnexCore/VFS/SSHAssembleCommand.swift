import Foundation

/// The shell commands that join an uploaded file's parts back together on the server — a segmented
/// SFTP upload's whole remote half (PLAN.md §4 ▸ *Still open*).
///
/// **The exec channel is the only route there is, and that is a measurement rather than a
/// preference.** `sftp(1)` has no verb that writes at an offset — `help` lists `put`, `put -a` and
/// `reput`, all of which append at the file's current length — so parts cannot be written into one
/// file concurrently and have to be sent under names of their own and joined afterwards. Joining is
/// `cat`, which is the *other* thing an SSH connection can do, and the third thing this project asks
/// an account for after §M22's subtree search and a download's ranges.
///
/// Four choices, each probed against a real `sshd` on 2026-09-01:
///
/// - **`cat`, not `dd`.** The tempting shape is to write each part straight into the destination at
///   its offset (`dd … seek=… conv=notrunc`), which would need no join and no second copy. `dd`
///   performs one `read()` per block and a short read gives a short block written at the *right*
///   offset with the rest of the part lost — BSD `dd` has no `iflag=fullblock` to prevent it — so
///   the one shape that removes the join is the one that can silently corrupt the middle of a file.
///   `cat` is stream-oriented and reads to completion. It costs a second pass over the bytes on the
///   server, measured at **1.9 GiB/s** — 0.55 s for a gibibyte, against the minutes its transfer
///   took — and the destination's size again in scratch until the join finishes.
/// - **Joined under a staging name, then renamed.** A redirect creates its target before `cat`
///   writes a byte, so joining straight into the destination would leave a *partial file under the
///   real name* whenever the server ran out of room — the one outcome this project holds to be
///   worse than no file. Renaming within the directory is atomic, so the destination appears whole
///   or not at all, which is more than the single-stream `put` this replaces can say.
/// - **The size is reported, and it is the only evidence there is.** Probed: a part that arrives
///   short joins perfectly happily — `cat` has nothing to compare against — and an account confined
///   to the `sftp` subsystem answers an exec request with the sentence "This service allows sftp
///   connections only." on **stdout**, exit 1, which is where this command's own answer goes. So
///   the caller checks the number against the file it sent and treats anything else, prose
///   included, as a refusal (``assembledSize(from:)``).
/// - **`/usr/bin/env` on every word.** An exec channel runs the user's login shell, which sources
///   their rc, and a shell *function* there shadows the binary — the same rule ``SSHFindCommand``
///   and ``SSHSegmentCommand`` already carry, applied to three more words.
///
/// Nothing here uses a shell construct beyond `&&`, `>` and `<`: the shell is whatever the account's
/// login shell happens to be, so a variable, a command substitution or a `for` loop would be a
/// portability assumption nobody has measured.
public enum SSHAssembleCommand {
    /// Join `parts`, in the order given, into `stagingPath` and print the byte count that landed.
    ///
    /// The count comes last so that a `cat` which failed prints nothing at all, and it is `wc -c`
    /// on the file rather than on the stream so it measures what is *on the disk* rather than what
    /// passed through.
    public static func join(_ parts: [UploadSegment], into stagingPath: String) -> String {
        let names = parts
            .sorted { $0.number < $1.number }
            .map { SSHShellQuote.quote($0.remotePath) }
            .joined(separator: " ")
        return "/usr/bin/env cat \(names) > \(SSHShellQuote.quote(stagingPath))"
            + " && /usr/bin/env wc -c < \(SSHShellQuote.quote(stagingPath))"
    }

    /// Put the joined file under its real name and sweep the parts away.
    ///
    /// Sent only once the size has been checked, which is what keeps a short join from ever
    /// reaching the destination. `mv` within one directory is a rename, so the file appears whole.
    public static func commit(
        _ parts: [UploadSegment],
        from stagingPath: String,
        to destination: String
    ) -> String {
        "/usr/bin/env mv \(SSHShellQuote.quote(stagingPath)) \(SSHShellQuote.quote(destination))"
            + " && " + remove(parts.map(\.remotePath))
    }

    /// Sweep away everything a failed or cancelled run left on the server.
    ///
    /// `rm -f` so it succeeds over parts that were never created, which is the ordinary shape of a
    /// run that failed early.
    public static func discard(_ parts: [UploadSegment], staging stagingPath: String) -> String {
        remove([stagingPath] + parts.map(\.remotePath))
    }

    /// Ask whether this account has an exec channel at all, by having it echo something only an
    /// answer could contain.
    ///
    /// A sentinel rather than a bare `true`, because the refusal is not an error: an `sftp`-only
    /// account answers *successfully-looking* prose on stdout, so "did anything come back" cannot
    /// tell the two apart and "did it come back with my token in it" can. The same shape
    /// ``SSHFindCommand`` gives its walk, where the root's own row is the sentinel.
    public static func probe(token: String) -> String {
        "/usr/bin/env echo \(SSHShellQuote.quote(token))"
    }

    /// Whether `output` is this account answering ``probe(token:)`` rather than refusing it.
    public static func answeredProbe(_ output: String?, token: String) -> Bool {
        guard let output else { return false }
        return output.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == token }
    }

    /// The byte count ``join(_:into:)`` reported, or `nil` when the answer was not a count.
    ///
    /// Reads the **last** non-empty line and requires it to be nothing but digits. Both halves earn
    /// their keep: the login shell's rc runs before the command and can print, so an earlier line is
    /// not necessarily ours; and an account with no exec channel answers with a sentence, which the
    /// digit rule turns into `nil` rather than into a number. `wc` pads its output with spaces on
    /// macOS, so the line is trimmed before it is read.
    public static func assembledSize(from output: String?) -> Int64? {
        guard let output else { return nil }
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last, !last.isEmpty,
              last.allSatisfy(\.isASCII), last.allSatisfy(\.isNumber) else { return nil }
        return Int64(last)
    }

    private static func remove(_ paths: [String]) -> String {
        "/usr/bin/env rm -f " + paths.map { SSHShellQuote.quote($0) }.joined(separator: " ")
    }
}
