import Foundation

/// When an upload is worth splitting into parts that go at once, how big a part should be, and how
/// many of them may be staged at a time.
///
/// The upload twin of ``SegmentedDownloadLimits``, and a separate table rather than a second name
/// for that one because an upload pays a cost a download does not: every part in flight is a slice
/// cut to a temp file first (``S3PartSlice``), and the parts are joined **on the server**, which
/// needs the destination's own bytes again in scratch until the join finishes. So the numbers here
/// answer to the disk on both ends as well as to the link, where a download's answer only to the
/// link.
///
/// Measured 2026-09-01 against a real `sshd` behind a 2 MB/s per-connection throttle — the
/// instrument that makes a parallel measurement mean anything on loopback, where nothing is the
/// bottleneck. A 32 MiB file: **one stream 16.85 s, four parts 4.32 s**, byte-identical, of which
/// the server-side join was 0.09 s.
public struct SegmentedUploadLimits: Sendable, Equatable {
    /// Above this, an upload is split. Below it, one `put` — the staging, the extra connections and
    /// the join are all overhead for a file a single stream finishes quickly anyway.
    public let threshold: Int64
    /// The smallest a part may be. It is what stops a barely-worthwhile file being cut into pieces
    /// whose connect, key exchange and authentication cost more than the bytes each one carries.
    public let minimumPartSize: Int64
    /// The part size used whenever the file is large enough to have more parts than can be in
    /// flight — i.e. the size that decides how much of a connection's time is handshake.
    public let preferredPartSize: Int64
    /// How many parts are sent at once. Every one is an `sftp` connection.
    public let maximumPartsInFlight: Int
    /// The most **local** scratch a run may occupy — the bound that turns "four parts at once" into
    /// a statable number of bytes. It binds only where a part has been grown past
    /// ``preferredPartSize``, which happens above about 312 GiB.
    public let stagingBudget: Int64
    /// The most parts one upload may have. Every part is a connection, so this is what stops a
    /// enormous file becoming an enormous number of handshakes.
    public let maximumParts: Int

    public init(
        threshold: Int64,
        minimumPartSize: Int64,
        preferredPartSize: Int64,
        maximumPartsInFlight: Int,
        stagingBudget: Int64,
        maximumParts: Int
    ) {
        self.threshold = threshold
        self.minimumPartSize = minimumPartSize
        self.preferredPartSize = preferredPartSize
        self.maximumPartsInFlight = maximumPartsInFlight
        self.stagingBudget = stagingBudget
        self.maximumParts = maximumParts
    }

    /// SFTP: split above 32 MiB, parts of 16–32 MiB, four at once, 512 MiB of scratch, 10 000 parts.
    ///
    /// **The threshold is twice the download's**, and the difference is the point rather than an
    /// oversight: a segmented download costs one connection per piece and nothing else, while an
    /// upload also cuts a slice on this disk, spends a connection on the join, and leaves the file's
    /// own bytes again in scratch **on the server** until that join finishes. A file a single `put`
    /// clears in a few seconds is not worth any of it.
    ///
    /// **The part size answers to the handshake.** A part is a fresh TCP connect, key exchange and
    /// authentication — measured at 64 ms on loopback and a real several round trips over a network
    /// — so what decides the floor is what fraction of a connection's life that is: at a
    /// per-connection 10 MB/s, a 16 MiB part is about 9 % handshake and a 4 MiB part 40 %. The
    /// ceiling is the other end of the same trade, since scratch is `maximumPartsInFlight` parts.
    ///
    /// **Four in flight** for the reason ``SegmentedDownloadLimits/sftp`` allows four ranges:
    /// OpenSSH's `MaxStartups` throttles unauthenticated connections above ten by default, and four
    /// leaves room for whatever else the account is doing.
    public static let sftp = SegmentedUploadLimits(
        threshold: 32 * 1024 * 1024,
        minimumPartSize: 16 * 1024 * 1024,
        preferredPartSize: 32 * 1024 * 1024,
        maximumPartsInFlight: 4,
        stagingBudget: 512 * 1024 * 1024,
        maximumParts: 10_000
    )
}

/// How one file is cut into parts on the way **up** — the pure arithmetic behind a segmented upload.
///
/// The fourth quadrant of a square this project already had three corners of: ``S3MultipartPlan``
/// for S3's uploads, ``SegmentedDownloadPlan`` for every backend's downloads, and this for SFTP's.
/// Everything that decides *what gets sent* lives here and is tested, so the orchestration in
/// ``SFTPBackend`` has no sizing rules of its own to get wrong. Parts are numbered from 1, which is
/// the order they are joined in and the one numbering an off-by-one could not survive.
///
/// **The size it is built from is the local file's own**, read with one `stat` this side of the
/// network — unlike a download's, which is a hint the caller already held because asking would cost
/// a whole connection. An upload's source is on this disk and cannot be stale.
public struct SegmentedUploadPlan: Sendable, Equatable {
    /// The size of the file being uploaded.
    public let totalSize: Int64
    /// The size of every part but the last.
    public let partSize: Int64
    /// How many parts are sent at once.
    public let partsInFlight: Int

    /// The plan for a file of `totalSize` bytes under `limits`, or `nil` when splitting it would buy
    /// nothing.
    ///
    /// The part size is the file divided into ``SegmentedUploadLimits/maximumPartsInFlight`` pieces,
    /// held between the floor and the preferred size — so a file barely over the threshold is cut
    /// into **equal** parts that finish together, and a large one is cut into preferred-size parts
    /// that run in batches. Equal parts matter only in the first regime and matter a lot there: with
    /// four connections and parts of 32, 32 and 1 MiB the run takes as long as the 32 MiB part,
    /// where three equal parts of 22 MiB finish a third sooner.
    ///
    /// It is then grown, rounded **up** to a whole mebibyte, if the file would otherwise need more
    /// than ``SegmentedUploadLimits/maximumParts``. Rounding up is what makes the count safe without
    /// a fudge factor: a larger part can only ever produce fewer of them.
    public init?(totalSize: Int64, limits: SegmentedUploadLimits) {
        guard totalSize > 0, limits.maximumPartsInFlight > 0, limits.maximumParts > 0 else {
            return nil
        }
        let even = Self.ceilingDivide(totalSize, Int64(limits.maximumPartsInFlight))
        var size = min(max(even, limits.minimumPartSize), limits.preferredPartSize)

        let mebibyte: Int64 = 1024 * 1024
        if Self.ceilingDivide(totalSize, size) > Int64(limits.maximumParts) {
            let required = Self.ceilingDivide(totalSize, Int64(limits.maximumParts))
            size = max(size, Self.ceilingDivide(required, mebibyte) * mebibyte)
        }

        let count = Self.ceilingDivide(totalSize, size)
        let affordable = Int(max(1, limits.stagingBudget / size))
        let inFlight = min(limits.maximumPartsInFlight, Int(count), affordable)

        // One part at a time is not a slower split, it is the single `put` in a more expensive
        // spelling — a slice on this disk, a second copy on the server's, and an extra connection
        // for the join, in exchange for nothing. Refused rather than run, which is where this
        // differs from ``S3MultipartPlan``: there a lone part still buys a retry unit smaller than
        // the file and a progress counter that moves, and here it buys neither.
        guard inFlight >= 2 else { return nil }
        self.init(totalSize: totalSize, partSize: size, partsInFlight: inFlight)
    }

    /// A plan with the part size and concurrency stated rather than derived.
    ///
    /// The *arithmetic* of cutting a file into parts is separate from the *policy* of how big one
    /// should be, exactly as ``SegmentedDownloadPlan`` and ``S3MultipartPlan`` both split the same
    /// pair — so this initializer holds the arithmetic and ``init(totalSize:limits:)`` applies the
    /// policy on top. It is what lets the range logic be exercised at sizes a real upload never
    /// uses.
    public init?(totalSize: Int64, partSize: Int64, partsInFlight: Int) {
        guard totalSize > 0, partSize > 0, partsInFlight > 0 else { return nil }
        self.totalSize = totalSize
        self.partSize = partSize
        self.partsInFlight = partsInFlight
    }

    /// Whether a file of this size should be split at all under `limits`.
    ///
    /// Asked before a plan is built, because the answer for a small file is "no plan" rather than
    /// "a plan with one part".
    public static func isWorthwhile(totalSize: Int64, limits: SegmentedUploadLimits) -> Bool {
        totalSize > limits.threshold
    }

    /// How many parts this file is cut into. Always at least 1.
    public var partCount: Int {
        Int(Self.ceilingDivide(totalSize, partSize))
    }

    /// The part numbers of each batch, in order — what the orchestration loops over.
    ///
    /// A batch is what bounds the scratch: its parts are sliced, sent and removed before the next
    /// one is cut, so peak local scratch is ``partsInFlight`` parts however large the file is.
    public var batches: [[Int]] {
        stride(from: 1, through: partCount, by: partsInFlight).map { first in
            Array(first...min(first + partsInFlight - 1, partCount))
        }
    }

    /// The peak local scratch this plan occupies — one batch's worth, and the number the staging
    /// budget exists to bound.
    public var stagingPeak: Int64 { partSize * Int64(partsInFlight) }

    /// The byte range of part `number`, counting from 1, or `nil` for a number outside the plan.
    ///
    /// The last part is whatever is left, and is the one allowed to be shorter than the others.
    public func range(ofPart number: Int) -> Range<Int64>? {
        guard number >= 1, number <= partCount else { return nil }
        let start = Int64(number - 1) * partSize
        return start..<min(start + partSize, totalSize)
    }

    /// The length of part `number`, or 0 when it is outside the plan.
    public func length(ofPart number: Int) -> Int64 {
        guard let range = range(ofPart: number) else { return 0 }
        return range.upperBound - range.lowerBound
    }

    /// Every part of this plan, each pointed at the local slice it is cut into and the remote name
    /// it lands under.
    ///
    /// The remote names sit **beside the destination**, because that is the one directory the run
    /// already knows is writable — a temp directory elsewhere on the server is a guess, and one on
    /// another filesystem would make the join a copy across volumes. They are hidden and carry a
    /// per-run token, so two uploads of the same file cannot collide and a leftover after a crash
    /// says which run it belonged to.
    public func parts(
        stagingIn directory: URL,
        destination: String,
        token: String
    ) -> [UploadSegment] {
        let remoteDirectory = Self.parentPath(of: destination)
        let leaf = destination.split(separator: "/").last.map(String.init) ?? destination
        return (1...partCount).compactMap { number in
            guard let range = range(ofPart: number) else { return nil }
            return UploadSegment(
                number: number,
                localPath: directory.appendingPathComponent(String(number)).path,
                remotePath: "\(remoteDirectory).dirnex-upload-\(token)-\(leaf).\(number)",
                range: range
            )
        }
    }

    /// The destination's directory, with its trailing slash — `/a/b/c.bin` gives `/a/b/`.
    ///
    /// Kept as a prefix rather than a path so a destination at the root (`/c.bin`) yields `/` and
    /// not the empty string, which would name a part relative to the login directory.
    private static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    private static func ceilingDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        divisor <= 0 ? 0 : (value + divisor - 1) / divisor
    }
}

/// One part of a file on its way up: which part it is, which bytes it covers, the slice it is cut
/// into on this machine, and the name it lands under on the server.
///
/// Bundled for the reason ``DownloadSegment`` and ``S3PartRequest`` are — the four never vary
/// independently, and a transport verb taking them apart would carry six parameters before it had a
/// progress hook.
public struct UploadSegment: Sendable, Equatable {
    /// Which part this is, counting from 1 — the order the server joins them in.
    public let number: Int
    /// The temp file this part's bytes are cut into, and the file the transfer sends.
    public let localPath: String
    /// The name this part lands under on the server, beside the destination.
    public let remotePath: String
    /// The half-open byte range of the source this part covers.
    public let range: Range<Int64>

    public init(number: Int, localPath: String, remotePath: String, range: Range<Int64>) {
        self.number = number
        self.localPath = localPath
        self.remotePath = remotePath
        self.range = range
    }

    /// How many bytes this part holds.
    public var length: Int64 { range.upperBound - range.lowerBound }
}
