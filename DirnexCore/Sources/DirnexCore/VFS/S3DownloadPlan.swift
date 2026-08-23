import Foundation

/// When a download is worth splitting into several ranges, and how wide the pieces are
/// (docs/HISTORY.md ▸ After M19).
///
/// All three are **policy**, not service limits — S3 will serve any `Range` a request asks for, so
/// nothing here is arithmetic the server forces. What decides them is the link: one download is one
/// `curl` and therefore **one TCP connection**, and a single connection is not what a link gives.
/// Measured on this project's own account 2026-08-20, alternating rounds over one whole object:
/// 1 connection 0.98 MB/s, 4 → 3.13 aggregate, 8 → 4.49; end to end, **1 segment ~36 s against
/// 8 segments ~5.4 s**, about 6,7×, with 8 winning every round.
///
/// They are constants measured on **one** link, which is the kind to re-measure before tuning
/// rather than raise on the strength of the same table — and to alternate rounds when re-measuring,
/// since the variance is large enough that one pair of runs proves either direction (2 segments read
/// 6.0 s and 15.4 s in the same set).
public enum S3DownloadLimits {
    /// Above this, a download is split. Below it, one stream — the request count is what the
    /// splitting costs, on a verb billed per thousand, and for a small object the handshake is
    /// most of the time anyway.
    public static let segmentedThreshold: Int64 = 8 * 1024 * 1024

    /// The smallest a segment may be. It is what stops a slightly-over-threshold object being cut
    /// into eight pieces whose per-request overhead is larger than the transfer each one performs.
    public static let minimumSegmentSize: Int64 = 4 * 1024 * 1024

    /// The most segments one download may use. Eight, because that is where the measured aggregate
    /// stopped climbing steeply — and because every segment is a request.
    public static let maximumSegments = 8
}

/// How one object is cut into byte ranges — the pure arithmetic behind a segmented download.
///
/// The twin of ``S3MultipartPlan``, deliberately: everything that decides *what gets asked for*
/// lives here and is tested, so the orchestration in ``S3Backend`` has no sizing rules of its own to
/// get wrong. Segments are numbered from 1 for the same reason parts are — one numbering everywhere
/// removes the place an off-by-one could survive.
///
/// **The size it is built from is a hint the caller already holds, never a probe.** A `HEAD` before
/// every download is a full handshake — measured at ~0.5 s time-to-first-byte for a small object,
/// since every `curl` re-signs and re-connects — which would roughly double the latency of the small
/// files Quick View fetches constantly, to answer a question that only matters above 8 MiB.
public struct S3DownloadPlan: Sendable, Equatable {
    /// The size of the object being downloaded.
    public let totalSize: Int64
    /// The size of every segment but the last.
    public let segmentSize: Int64

    /// The plan for an object of `totalSize` bytes, or `nil` when there is nothing to cut.
    ///
    /// The segment count is the file's own (`totalSize / minimumSegmentSize`, floored so no segment
    /// is under the floor) bounded by ``S3DownloadLimits/maximumSegments``, and the *size* is then
    /// derived from that count by rounding **up**. Rounding up is what makes the count safe without
    /// a fudge factor: a larger segment can only ever produce fewer of them, so
    /// ``segmentCount`` never exceeds the maximum by construction — and it is why the count is
    /// derived from the size below rather than stored, since the two can legitimately differ by one
    /// (100 bytes in 6 nominal pieces is 5 pieces of 17).
    public init?(totalSize: Int64) {
        guard totalSize > 0 else { return nil }
        let affordable = Int(totalSize / S3DownloadLimits.minimumSegmentSize)
        let count = min(S3DownloadLimits.maximumSegments, max(1, affordable))
        self.init(totalSize: totalSize, segmentSize: Self.ceilingDivide(totalSize, Int64(count)))
    }

    /// A plan with the segment size stated rather than derived.
    ///
    /// The *arithmetic* of cutting an object into ranges is separate from the *policy* of how wide a
    /// range should be, and only the policy is about this link — so this initializer holds the
    /// arithmetic and ``init(totalSize:)`` applies the policy on top, exactly as ``S3MultipartPlan``
    /// splits the same pair. It is what lets the range logic be exercised at sizes a real download
    /// never uses.
    public init?(totalSize: Int64, segmentSize: Int64) {
        guard totalSize > 0, segmentSize > 0 else { return nil }
        self.totalSize = totalSize
        self.segmentSize = segmentSize
    }

    /// Whether an object of this size should be split at all.
    ///
    /// Asked before a plan is built, because the answer for a small object is "no plan" rather than
    /// "a plan with one segment": one segment is the plain download in a more expensive spelling —
    /// a temp file, an assembly pass, and no second connection to show for it.
    public static func isWorthwhile(totalSize: Int64) -> Bool {
        totalSize > S3DownloadLimits.segmentedThreshold
    }

    /// How many segments this object is cut into. Always at least 1, and never more than
    /// ``S3DownloadLimits/maximumSegments`` when the size was derived.
    public var segmentCount: Int {
        Int(Self.ceilingDivide(totalSize, segmentSize))
    }

    /// The byte range of segment `number`, counting from 1, or `nil` for a number outside the plan.
    ///
    /// The last segment is whatever is left, and is the one allowed to be shorter than the others.
    public func range(ofSegment number: Int) -> Range<Int64>? {
        guard number >= 1, number <= segmentCount else { return nil }
        let start = Int64(number - 1) * segmentSize
        return start..<min(start + segmentSize, totalSize)
    }

    /// The length of segment `number`, or 0 when it is outside the plan.
    public func length(ofSegment number: Int) -> Int64 {
        guard let range = range(ofSegment: number) else { return 0 }
        return range.upperBound - range.lowerBound
    }

    /// Every segment of this plan, each pointed at its own file under `directory`.
    ///
    /// The names are the segment numbers, so the directory reads as the plan does and a leftover
    /// after a crash says which piece it was. The caller owns the directory and removes it whole.
    public func segments(under directory: URL) -> [S3DownloadSegment] {
        (1...segmentCount).compactMap { number in
            guard let range = range(ofSegment: number) else { return nil }
            return S3DownloadSegment(
                number: number,
                localPath: directory.appendingPathComponent(String(number)).path,
                range: range
            )
        }
    }

    private static func ceilingDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        divisor <= 0 ? 0 : (value + divisor - 1) / divisor
    }
}

/// One range of an object on its way down: which piece it is, which bytes it covers, and the file
/// it lands in.
///
/// Bundled for the reason ``S3PartRequest`` is — the three never vary independently, and a transport
/// verb taking them apart would carry five parameters before it had a progress hook.
public struct S3DownloadSegment: Sendable, Equatable {
    /// Which segment this is, counting from 1 — the order ``S3SegmentAssembly`` joins them in.
    public let number: Int
    /// The file this segment's bytes are written to, and read back out of when assembling.
    public let localPath: String
    /// The half-open byte range of the object this segment covers.
    public let range: Range<Int64>

    public init(number: Int, localPath: String, range: Range<Int64>) {
        self.number = number
        self.localPath = localPath
        self.range = range
    }

    /// How many bytes this segment should hold once it has landed.
    public var length: Int64 { range.upperBound - range.lowerBound }

    /// The value of an HTTP `Range` header's byte spec, which is **inclusive at both ends** where
    /// the Swift range is half-open. One character, and it is the difference between a correct
    /// assembly and a file with a byte missing at every seam.
    public var headerValue: String { "\(range.lowerBound)-\(range.upperBound - 1)" }
}
