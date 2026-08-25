import Foundation

/// The write-out for one segment of a **parallel** download, and the reader for what a whole run
/// produces (docs/HISTORY.md ▸ After M19).
///
/// The upload half's twin, over the same mechanism (``S3IndexedWriteOut``) and differing only in
/// what a *download* has to say for itself: a status, and the bytes that landed. There is no ETag —
/// nothing is being assembled by the service — and no `size_upload`, since a section that sends
/// nothing would only ever report zero.
///
/// The labels are indexed for the reason the parts' are, and it was designed out rather than probed:
/// several sections printing into one stream can interleave, so a reader keyed on a bare
/// `s3-status=` would attribute whichever line arrived to whichever section it was expecting. That
/// failure is *intermittent* by nature, which is the kind worth removing by construction rather
/// than measuring.
public struct S3SegmentWriteOut: Sendable, Equatable {
    /// What one segment reported.
    public struct Fields: Sendable, Equatable {
        /// The HTTP status. A satisfied `Range` request answers **206**, not 200 — which is why
        /// nothing anywhere in this backend tests a status for equality with 200
        /// (``S3Response/isSuccess``).
        public let status: Int
        /// Bytes this section received.
        public let bytesDownloaded: Int64
    }

    /// The `write-out` value for segment `number`.
    public static func format(forSegment number: Int) -> String {
        S3IndexedWriteOut.format(
            label: Self.label,
            index: number,
            fields: [("status", "%{http_code}"), ("down", "%{size_download}")]
        )
    }

    private static let label = "seg"
    private var reader = S3IndexedWriteOut(label: S3SegmentWriteOut.label)

    public init() {}

    /// Fold the next piece of the run's stderr in.
    public mutating func consume(_ text: String) {
        reader.consume(text)
    }

    /// Read a complete capture in one go.
    public static func parse(stderr: String) -> S3SegmentWriteOut {
        var out = S3SegmentWriteOut()
        out.reader.consume(stderr)
        out.reader.flush()
        return out
    }

    /// What segment `number` reported, or `nil` when nothing of it has arrived yet.
    ///
    /// A segment with no status is *not* a segment with status 0: a section `curl` never ran prints
    /// nothing at all, and the caller has to tell that from a section that ran and was refused.
    public func fields(forSegment number: Int) -> Fields? {
        guard let raw = reader.values[number], let status = raw["status"].flatMap(Int.init) else {
            return nil
        }
        return Fields(status: status, bytesDownloaded: raw["down"].flatMap(Int64.init) ?? 0)
    }
}
