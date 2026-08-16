import Foundation

/// Reads `curl`'s progress meter as it arrives, so a transfer that is one long invocation can still
/// report where it has got to (PLAN.md §M21).
///
/// An upload is a single `curl -T` that says nothing until it exits, so the byte count reaches the
/// queue exactly once — when there is nothing left to report. Measured 2026-08-14 against the real
/// endpoint, 29 MB took **99 seconds**, every one of them silent, and the bar sat where the job was
/// enqueued. Nothing local can be watched for an upload the way a download's growing destination
/// file can, so the meter is the only source there is.
///
/// It is parsed rather than assumed. Captured from that same run, the stream is:
///
/// ```text
///   % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
///                                  Dload  Upload   Total   Spent    Left  Speed
/// \r  0 27.6M    0     0    0 65098      0  69944  0:06:54 --:--:--  0:06:54 69922
/// \r  1 27.6M    0     0    1  447k      0   228k  0:02:03  0:00:01  0:02:02  228k
/// ```
///
/// Three facts from that capture decide the whole implementation:
///
/// - **Rows are separated by carriage returns**, since the meter overwrites itself in place — so a
///   reader splitting on newlines alone sees one enormous line and never reports anything.
/// - **The leading integer is the overall percentage**, in either direction: it is `% Received` for
///   a download and `% Xferd` for an upload, and `curl` puts the same number first in both. Every
///   other column is human-rounded to three significant figures (`447k`, `27.6M`), so the percentage
///   is the one field that is exact as printed. At 1 % granularity a transfer reports about a
///   hundred times, which is what a bar needs and no more.
/// - **Anything that is not a meter row is ignorable**, and there is always some: the two header
///   lines, `curl`'s own error prose, and the labelled `s3-…` write-out fields that share this
///   stream. All of them fail to start with an integer, which is the whole filter — the same
///   "labelled lines make the prose ignorable" argument ``S3WriteOut`` rests on, from the other end.
///
/// The percentage never goes backwards. `curl` does not print a decreasing one, and a caller
/// converting it to a delta would otherwise have to defend against a negative.
///
/// ``prose`` is the other half, and it is what lets a transport read this stream at all: `curl`
/// writes its *errors* here too. Measured 2026-08-16 against a local server, letting the meter
/// through takes a refused upload's stderr from **61 bytes** —
/// `curl: (9) Server denied you to change to the given directory` — to **378**, the rest of it a
/// table. So the same filter that finds the rows has to hand back what is left.
///
/// What that is worth is narrower than it looks, and is worth stating precisely rather than
/// generously. `FTPTransportError.classify` reads the *last* three-digit 4xx/5xx token in the
/// stream for two exit codes, so with the table in scope a **speed column of `553k`** on a failed
/// transfer would be read as FTP reply 553 and classified as a permission failure instead of a
/// missing path. That is reachable rather than observed — every failure provoked in the same run
/// classified identically either way, because a transfer that fails has usually not moved enough
/// for its meter to print anything but zeros. The other half is plainer: `.failure` carries this
/// text as *the server's own words*, so it should not contain a table whatever eventually reads it.
public struct CurlProgressMeter: Sendable, Equatable {
    /// The most recent percentage `curl` has printed, or `nil` before the first complete row.
    public private(set) var percentComplete: Int?

    /// The tail of the stream that has not been terminated yet. A chunked reader splits rows
    /// wherever the pipe happens to fill, so a half-written row is held rather than parsed — a
    /// truncated `1 27.6M …` would otherwise read as a plausible percentage of its own.
    private var pending = ""

    /// Rows that were not the meter's, from the first meter row onwards.
    private var proseRows: [String] = []

    /// Rows that were not the meter's and arrived *before* any meter row — the table's own two
    /// header lines, or genuine prose from a run that never started a transfer. Which of the two it
    /// is cannot be known until a meter row does or does not follow, so it is held until then.
    private var preambleRows: [String] = []

    public init() {}

    /// Fold the next piece of `curl`'s stderr in.
    public mutating func consume(_ text: String) {
        pending += text
        // Both terminators, and neither is optional: rows are `\r`-separated while the headers and
        // the write-out fields that follow the last row are `\n`-separated.
        while let index = pending.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            let row = String(pending[..<index])
            pending = String(pending[pending.index(after: index)...])
            absorb(row)
        }
    }

    /// Everything on this stream that the meter did not write — `curl`'s own error prose, and
    /// whatever else shares stderr — with the table dropped.
    ///
    /// **The two header lines are defined structurally rather than by their wording**: they are the
    /// rows that precede the first meter row, and nothing else can be, because `curl` prints them
    /// when a transfer starts and an error that arrives first is terminal. So a run that never
    /// reaches a transfer (an unreachable host, a refused login before the meter opens) keeps every
    /// word it printed, while a run that does drops exactly the table. Matching `% Total` or `Dload`
    /// instead would have been a rule about this version's phrasing.
    ///
    /// The unterminated tail counts, since `curl`'s last line need not end in a newline and it is
    /// the one carrying the diagnosis. A *partial meter row* is excluded by the same test that
    /// excludes a complete one.
    public var prose: String {
        // `preambleRows` is emptied by the first meter row, so prepending it unconditionally is the
        // "no transfer ever started" case and nothing else.
        var rows = preambleRows + proseRows
        if !Self.isBlank(pending), !Self.isMeterRow(pending) { rows.append(pending) }
        return rows.joined(separator: "\n")
    }

    /// The prose in a complete stderr capture — the one-shot form, for a caller that has the whole
    /// stream in hand rather than a chunk at a time.
    ///
    /// It is a *second* pass over bytes the live meter has already seen, deliberately: a chunked
    /// reader has to skip a chunk whose UTF-8 decode fails at a read boundary, which costs an
    /// estimate nothing and would cost an error message a fragment of itself. Progress comes from
    /// the reader that runs during the transfer; the words come from the complete capture.
    public static func prose(in stderr: String) -> String {
        var meter = CurlProgressMeter()
        meter.consume(stderr)
        return meter.prose
    }

    /// File one row under the meter, the preamble, or the prose.
    private mutating func absorb(_ row: String) {
        guard !Self.isBlank(row) else { return }
        guard let percent = Self.percentage(inRow: row) else {
            if percentComplete == nil {
                preambleRows.append(row)
            } else {
                proseRows.append(row)
            }
            return
        }
        percentComplete = max(percentComplete ?? 0, percent)
        // Whatever preceded the first row is now known to have been the table's header.
        preambleRows.removeAll()
    }

    /// How many of `totalBytes` the meter says have moved, or `nil` before the first row.
    ///
    /// The caller supplies the total because it knows it exactly — the local file's own size for an
    /// upload — where the meter's `Total` column is rounded for display. Multiplying an exact size
    /// by an exact percentage keeps the estimate's only error the percentage's own rounding.
    ///
    /// The multiplication cannot overflow: S3 stops at 5 TiB (``S3MultipartLimits/maximumObjectSize``),
    /// and a hundred times that is four orders of magnitude inside `Int64`.
    public func bytesTransferred(ofTotal totalBytes: Int64) -> Int64? {
        guard let percentComplete, totalBytes > 0 else { return nil }
        return min(totalBytes, totalBytes * Int64(percentComplete) / 100)
    }

    /// Whether a row is the meter's — the one filter, so "which rows are the table" and "which rows
    /// are left over" can never answer differently.
    private static func isMeterRow(_ row: String) -> Bool {
        percentage(inRow: row) != nil
    }

    /// The percentage a meter row leads with, or `nil` when the row is not one. The range is what
    /// makes it a *percentage* rather than merely a number, and it is what keeps a line like
    /// `29000000 bytes written` on the prose side rather than silently swallowed as a row.
    private static func percentage(inRow row: String) -> Int? {
        guard let token = row.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first, let percent = Int(token), (0...100).contains(percent) else { return nil }
        return percent
    }

    private static func isBlank(_ row: String) -> Bool {
        row.allSatisfy(\.isWhitespace)
    }
}
