import Foundation

/// Builds the one shell command that reads a **byte range** of a remote file over an SSH exec
/// channel — a segmented SFTP download's whole remote half (docs/HISTORY.md ▸ After M19).
///
/// **The exec channel is the only route there is, and that is a measurement rather than a
/// preference.** The system `curl` is built without libssh2 — its protocol list has no `sftp` and no
/// `scp` — so the one-`curl -Z`-with-N-sections shape that serves S3 and FTP does not exist here;
/// and `sftp(1)` has no range verb at all (`get -a` resumes to EOF, with no way to stop). So a
/// segment is `ssh <host> <command>`, which is the second thing this project already asks an SSH
/// account to do (PLAN.md §M22's subtree search).
///
/// Three choices, each probed against a real `sshd` on 2026-08-24:
///
/// - **`tail -c +N | head -c M`, not `dd`.** Both are byte-exact in practice and both reassembled
///   SHA-256 identical, but only the pipeline is exact *by construction*: `dd` performs one `read()`
///   per block and a short read gives a short piece, which BSD `dd` has no `iflag=fullblock` to
///   prevent. `tail` and `head` are stream-oriented and read to completion, and they need no block
///   alignment — so the shared ``SegmentedDownloadPlan`` works unchanged rather than growing an
///   alignment rule for one backend.
/// - **`tail -c +N` seeks.** The obvious worry is that skipping to a late offset costs a read of
///   everything before it; measured over a 256 MiB file, the same 8 MiB piece took **0.31 s at
///   offset 1 and 0.28 s at offset 224 MiB**. It is O(1) in the offset.
/// - **`/usr/bin/env` on both halves.** An exec channel runs the user's login shell, which sources
///   their rc, and a shell *function* there shadows the binary — probed, a `dd() { echo SHADOWED; }`
///   did exactly that, while `/usr/bin/env dd` returned the real bytes. The same rule
///   ``SSHFindCommand`` already carries, applied to two more words.
///
/// **What this command cannot do is report a failure, and the caller must not expect it to.** A
/// pipeline's exit status is its *last* stage's, so a `tail` that could not open the file is masked
/// by a `head` that exits 0: measured, a missing remote path gives `ssh` exit **0** and a **zero-byte**
/// piece. `set -o pipefail` is not POSIX and the shell here is whatever the user's login shell is, so
/// there is nothing to set. That is why ``SegmentAssembly``'s length check is load-bearing rather
/// than defensive — it is the only thing that distinguishes a piece from a failure — and why a
/// segmented SFTP download never diagnoses anything: it either succeeds or hands over to the plain
/// `sftp` download, which reports the real reason.
public enum SSHSegmentCommand {
    /// Read `range` of `remotePath` to stdout.
    ///
    /// `tail -c +N` counts from **one**, where the range's lower bound counts from zero — one
    /// character, and it is the difference between a correct assembly and every piece starting a
    /// byte early.
    public static func read(_ remotePath: String, range: Range<Int64>) -> String {
        let quoted = SSHShellQuote.quote(remotePath)
        let length = range.upperBound - range.lowerBound
        return "/usr/bin/env tail -c +\(range.lowerBound + 1) \(quoted)"
            + " | /usr/bin/env head -c \(length)"
    }
}
