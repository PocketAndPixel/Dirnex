import Foundation

/// When a download is worth splitting into several ranges, and how wide the pieces are.
///
/// All three are **policy**, not protocol limits — every backend this applies to will serve any
/// range a request asks for, so nothing here is arithmetic a server forces. What decides them is
/// what one connection costs and what one connection *gets*, and those differ enough between
/// protocols that the numbers are a per-backend value rather than a constant
/// (``s3`` against ``ftp``).
///
/// They are measured on **one** link apiece, which is the kind to re-measure before tuning rather
/// than raise on the strength of the same table — and to alternate rounds when re-measuring, since
/// the variance is large enough that one pair of runs proves either direction.
public struct SegmentedDownloadLimits: Sendable, Equatable {
    /// Above this, a download is split. Below it, one stream — the request count is what the
    /// splitting costs, and for a small file the handshake is most of the time anyway.
    public let threshold: Int64
    /// The smallest a segment may be. It is what stops a barely-worthwhile file being cut into
    /// pieces whose per-request overhead is larger than the transfer each one performs.
    public let minimumSegmentSize: Int64
    /// The most segments one download may use. Every segment is a request, and — over FTP — a
    /// **login**.
    public let maximumSegments: Int

    public init(threshold: Int64, minimumSegmentSize: Int64, maximumSegments: Int) {
        self.threshold = threshold
        self.minimumSegmentSize = minimumSegmentSize
        self.maximumSegments = maximumSegments
    }

    /// S3 over HTTPS: 8 MiB, 4 MiB, 8.
    ///
    /// One download is one `curl` and therefore **one TCP connection**, and a single connection is
    /// not what a link gives. Measured on this project's own account 2026-08-20, alternating rounds
    /// over one whole object: 1 connection 0.98 MB/s, 4 → 3.13 aggregate, 8 → 4.49; end to end,
    /// **1 segment ~36 s against 8 segments ~5.4 s**, about 6,7×, with 8 winning every round. A
    /// segment costs a TLS handshake and nothing else — there is no session to establish — which is
    /// why the threshold can sit as low as 8 MiB.
    public static let s3 = SegmentedDownloadLimits(
        threshold: 8 * 1024 * 1024,
        minimumSegmentSize: 4 * 1024 * 1024,
        maximumSegments: 8
    )

    /// FTP: 16 MiB, 8 MiB, 4 — **half of S3's ceiling and twice its threshold**, because over FTP a
    /// segment is not a request, it is a *login*.
    ///
    /// Measured 2026-08-24 against a real server: eight sections opened **eight separate control
    /// connections and eight separate logins**, all within about a millisecond, and each sent its
    /// own `REST`+`RETR`. So the fixed cost per segment is a TCP connect, a banner, `USER`, `PASS`,
    /// a TLS handshake for FTPS, and `PASV` — several round trips rather than one, which is what
    /// pushes the threshold up.
    ///
    /// The ceiling is the more important half and it is about **refusal, not cost**: servers cap
    /// concurrent connections per address, and a capped server does not degrade — it fails the run.
    /// With a cap of 2 and eight sections, two completed and six were refused `421`. Four sections
    /// meet fewer such caps, and four already buys 4× where the bottleneck is per-connection
    /// (measured on a 32 MiB file with a 4 MB/s per-connection cap, alternating rounds: 1 stream
    /// **16.02 s**, 4 segments **4.01 s**, 8 segments **2.01 s**, 3/3 each). What covers the rest is
    /// not a smaller number but the fallback — ``SegmentedDownloadSupport``.
    public static let ftp = SegmentedDownloadLimits(
        threshold: 16 * 1024 * 1024,
        minimumSegmentSize: 8 * 1024 * 1024,
        maximumSegments: 4
    )

    /// SFTP: the same three numbers as ``ftp``, arrived at from different measurements — which is
    /// why it is its own table rather than a second name for that one.
    ///
    /// A segment here is an **SSH exec channel**, so its fixed cost is a TCP connect, a key
    /// exchange and an authentication — dearer than FTP's login and much dearer than S3's TLS
    /// handshake, which is what keeps the threshold at 16 MiB rather than S3's 8. The ceiling of
    /// four is not about caps on concurrent *logins* but about OpenSSH's `MaxStartups`, whose
    /// default throttles unauthenticated connections above ten: four leaves room for whatever else
    /// the account is doing.
    ///
    /// They coincide today and are free to diverge: the reasons do not share a cause, and a table
    /// per protocol is what makes changing one of them a one-line decision rather than an
    /// archaeology exercise.
    public static let sftp = SegmentedDownloadLimits(
        threshold: 16 * 1024 * 1024,
        minimumSegmentSize: 8 * 1024 * 1024,
        maximumSegments: 4
    )
}

/// How one file is cut into byte ranges — the pure arithmetic behind a segmented download.
///
/// The twin of ``S3MultipartPlan``, deliberately: everything that decides *what gets asked for*
/// lives here and is tested, so the orchestration in a backend has no sizing rules of its own to get
/// wrong. Segments are numbered from 1 for the same reason parts are — one numbering everywhere
/// removes the place an off-by-one could survive.
///
/// **The size it is built from is a hint the caller already holds, never a probe.** Asking the
/// server first is a full round trip — measured at ~0.5 s time-to-first-byte for a small S3 object,
/// since every `curl` re-signs and re-connects — which would roughly double the latency of the small
/// files Quick View fetches constantly, to answer a question that only matters above the threshold.
public struct SegmentedDownloadPlan: Sendable, Equatable {
    /// The size of the file being downloaded.
    public let totalSize: Int64
    /// The size of every segment but the last.
    public let segmentSize: Int64

    /// The plan for a file of `totalSize` bytes under `limits`, or `nil` when there is nothing to
    /// cut.
    ///
    /// The segment count is the file's own (`totalSize / minimumSegmentSize`, floored so no segment
    /// is under the floor) bounded by ``SegmentedDownloadLimits/maximumSegments``, and the *size* is
    /// then derived from that count by rounding **up**. Rounding up is what makes the count safe
    /// without a fudge factor: a larger segment can only ever produce fewer of them, so
    /// ``segmentCount`` never exceeds the maximum by construction — and it is why the count is
    /// derived from the size below rather than stored, since the two can legitimately differ by one
    /// (100 bytes in 6 nominal pieces is 5 pieces of 17).
    public init?(totalSize: Int64, limits: SegmentedDownloadLimits) {
        guard totalSize > 0 else { return nil }
        let affordable = Int(totalSize / limits.minimumSegmentSize)
        let count = min(limits.maximumSegments, max(1, affordable))
        self.init(totalSize: totalSize, segmentSize: Self.ceilingDivide(totalSize, Int64(count)))
    }

    /// A plan with the segment size stated rather than derived.
    ///
    /// The *arithmetic* of cutting a file into ranges is separate from the *policy* of how wide a
    /// range should be, and only the policy is about a particular link — so this initializer holds
    /// the arithmetic and ``init(totalSize:limits:)`` applies the policy on top, exactly as
    /// ``S3MultipartPlan`` splits the same pair. It is what lets the range logic be exercised at
    /// sizes a real download never uses.
    public init?(totalSize: Int64, segmentSize: Int64) {
        guard totalSize > 0, segmentSize > 0 else { return nil }
        self.totalSize = totalSize
        self.segmentSize = segmentSize
    }

    /// Whether a file of this size should be split at all under `limits`.
    ///
    /// Asked before a plan is built, because the answer for a small file is "no plan" rather than
    /// "a plan with one segment": one segment is the plain download in a more expensive spelling —
    /// a temp file, an assembly pass, and no second connection to show for it.
    public static func isWorthwhile(totalSize: Int64, limits: SegmentedDownloadLimits) -> Bool {
        totalSize > limits.threshold
    }

    /// How many segments this file is cut into. Always at least 1, and never more than the limits'
    /// maximum when the size was derived.
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
    public func segments(under directory: URL) -> [DownloadSegment] {
        (1...segmentCount).compactMap { number in
            guard let range = range(ofSegment: number) else { return nil }
            return DownloadSegment(
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

/// One range of a file on its way down: which piece it is, which bytes it covers, and the file it
/// lands in.
///
/// Bundled for the reason ``S3PartRequest`` is — the three never vary independently, and a transport
/// verb taking them apart would carry five parameters before it had a progress hook.
public struct DownloadSegment: Sendable, Equatable {
    /// Which segment this is, counting from 1 — the order ``SegmentAssembly`` joins them in.
    public let number: Int
    /// The file this segment's bytes are written to, and read back out of when assembling.
    public let localPath: String
    /// The half-open byte range of the file this segment covers.
    public let range: Range<Int64>

    public init(number: Int, localPath: String, range: Range<Int64>) {
        self.number = number
        self.localPath = localPath
        self.range = range
    }

    /// How many bytes this segment should hold once it has landed.
    public var length: Int64 { range.upperBound - range.lowerBound }

    /// The value `curl`'s `--range` takes, which is **inclusive at both ends** where the Swift range
    /// is half-open. One character, and it is the difference between a correct assembly and a byte
    /// missing at every seam.
    ///
    /// One spelling for both protocols, and that it *is* one was measured rather than assumed: over
    /// HTTP it becomes a `Range:` header, and over FTP a `REST <first>` with `curl` stopping the
    /// read at `last` — different mechanisms, the same argument, and the same exact bytes
    /// (2026-08-24, eight pieces of a 40 MiB file reassembling SHA-256 identical).
    public var headerValue: String { "\(range.lowerBound)-\(range.upperBound - 1)" }
}
