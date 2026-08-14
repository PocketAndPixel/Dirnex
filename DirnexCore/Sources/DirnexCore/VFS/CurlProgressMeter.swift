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
public struct CurlProgressMeter: Sendable, Equatable {
    /// The most recent percentage `curl` has printed, or `nil` before the first complete row.
    public private(set) var percentComplete: Int?

    /// The tail of the stream that has not been terminated yet. A chunked reader splits rows
    /// wherever the pipe happens to fill, so a half-written row is held rather than parsed — a
    /// truncated `1 27.6M …` would otherwise read as a plausible percentage of its own.
    private var pending = ""

    public init() {}

    /// Fold the next piece of `curl`'s stderr in.
    public mutating func consume(_ text: String) {
        pending += text
        // Both terminators, and neither is optional: rows are `\r`-separated while the headers and
        // the write-out fields that follow the last row are `\n`-separated.
        while let index = pending.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            let row = String(pending[..<index])
            pending = String(pending[pending.index(after: index)...])
            guard let percent = Self.percentage(inRow: row) else { continue }
            percentComplete = max(percentComplete ?? 0, percent)
        }
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

    /// The percentage a meter row leads with, or `nil` when the row is not one.
    private static func percentage(inRow row: String) -> Int? {
        guard let token = row.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first, let percent = Int(token), (0...100).contains(percent) else { return nil }
        return percent
    }
}
