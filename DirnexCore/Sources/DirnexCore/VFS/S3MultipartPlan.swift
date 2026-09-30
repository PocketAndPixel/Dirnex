import Foundation

/// S3's own limits on an upload, and the two this project chooses on top of them (PLAN.md §M21).
///
/// The first four are the service's and are not ours to tune: a request outside them is refused by
/// the server, so they are the arithmetic every plan has to land inside. The last two are policy —
/// where a single `PUT` stops being the right shape, and how big a part should be when nothing
/// forces the answer.
public enum S3MultipartLimits {
    /// The smallest a part may be, except the last one. A short non-final part is refused with
    /// `EntityTooSmall`, so this is the floor every part size is measured against.
    public static let minimumPartSize: Int64 = 5 * 1024 * 1024

    /// The largest a single part may be.
    public static let maximumPartSize: Int64 = 5 * 1024 * 1024 * 1024

    /// The most parts one upload may have. This is what makes the part size a *function* of the
    /// file rather than a constant: a fixed 16 MiB part stops working at 160 GiB.
    public static let maximumPartCount = 10_000

    /// The largest object S3 will assemble — 5 TiB.
    public static let maximumObjectSize: Int64 = 5 * 1024 * 1024 * 1024 * 1024

    /// Above this, an upload goes multipart. Policy, not a service limit.
    ///
    /// The service only *forces* multipart above the 5 GiB single-`PUT` ceiling, so a threshold two
    /// orders of magnitude below that is buying something else, and it is worth naming what:
    ///
    /// - **A retry unit smaller than the file.** A single `PUT` that fails at 99 % has moved nothing;
    ///   a failed part costs one part.
    /// - **A progress counter that moves.** The whole object transfers as one `curl` invocation, so
    ///   the single-`PUT` path can only report its bytes *once, at the end* — a 4 GiB upload shows
    ///   nothing moving for its entire duration. Each part reports as it lands.
    ///
    /// The cost is requests, and it is small enough to state exactly: a 1 GiB file becomes 1 + 64 + 1
    /// requests instead of 1, on a verb billed per thousand. Below the threshold the single `PUT`
    /// stays, because for a small file one request really is the better shape.
    public static let multipartThreshold: Int64 = 64 * 1024 * 1024

    /// The part size used whenever ``maximumPartCount`` does not force a larger one.
    public static let preferredPartSize: Int64 = 16 * 1024 * 1024

    /// How many parts a batch sends at once. Policy, and the reason a large upload finishes in a
    /// fraction of the time it used to.
    ///
    /// One part is one TCP connection, and a single connection is not what a link gives: measured
    /// on the account this project was built against (docs/HISTORY.md ▸ After M19, the segmented-download probe),
    /// one stream carried 0.98 MB/s where four carried **3.13** and eight **4.49** aggregate. The
    /// same arithmetic is what makes a sequential multipart upload the slow shape — it sends one
    /// 16 MiB part at a time over one connection, however much headroom the link has.
    ///
    /// Four rather than eight, because an upload pays in **disk** what a download does not: every
    /// part in flight is a slice cut to a temp file first (``S3PartSlice``), so the staged cost is
    /// this many parts at once. Eight would buy perhaps a third more throughput for twice the
    /// scratch space, on a machine that may be nearly full — and the number is a constant measured
    /// on one link, so it is the kind that should be re-measured before it is tuned rather than
    /// raised on the strength of the same table.
    public static let preferredPartsInFlight = 4

    /// The most scratch space a batch may occupy — the bound that turns "four parts at once" into
    /// a statable number of bytes.
    ///
    /// It binds only where a part is enormous: the plan grows the part size past 16 MiB only above
    /// 156 GiB, so every ordinary upload stages 64 MiB and nothing else. Above that, concurrency
    /// gives way rather than the disk (a 1 TiB object's 128 MiB parts go two at a time).
    public static let stagingBudget: Int64 = 512 * 1024 * 1024
}

/// How one file is cut into parts — the pure arithmetic behind a multipart upload.
///
/// Everything that decides *what gets sent* lives here and is tested, so the orchestration in
/// ``S3Backend`` has no sizing rules of its own to get wrong. The part numbers are 1-based, which is
/// S3's numbering and not a translation this type performs: a part numbered 0 is rejected by the
/// service, so counting from 1 everywhere removes the one place an off-by-one could survive.
public struct S3MultipartPlan: Sendable, Equatable {
    /// The size of the file being uploaded.
    public let totalSize: Int64
    /// The size of every part but the last.
    public let partSize: Int64

    /// The plan for a file of `totalSize` bytes, or `nil` when S3 cannot hold it at all.
    ///
    /// The part size is the larger of ``S3MultipartLimits/preferredPartSize`` and the smallest size
    /// that fits the file into ``S3MultipartLimits/maximumPartCount`` parts, rounded **up** to a
    /// whole mebibyte. Rounding up is what makes the count safe without a fudge factor: a larger
    /// part can only ever produce fewer parts, so `ceil(total / partSize) <= maximumPartCount` holds
    /// by construction rather than by leaving headroom and hoping.
    public init?(totalSize: Int64) {
        guard totalSize > 0, totalSize <= S3MultipartLimits.maximumObjectSize else { return nil }

        let mebibyte: Int64 = 1024 * 1024
        let required = Self.ceilingDivide(totalSize, Int64(S3MultipartLimits.maximumPartCount))
        let rounded = Self.ceilingDivide(required, mebibyte) * mebibyte
        let size = max(S3MultipartLimits.preferredPartSize, rounded)
        guard size <= S3MultipartLimits.maximumPartSize else { return nil }

        self.init(totalSize: totalSize, partSize: size)
    }

    /// A plan with the part size stated rather than derived.
    ///
    /// The *arithmetic* of cutting a file into parts is separate from the *policy* of how big a part
    /// should be, and only the policy is S3's business: this initializer holds the arithmetic, and
    /// ``init(totalSize:)`` is the one that applies the service's rules on top. Keeping them apart
    /// is what lets the range logic be exercised at sizes a real upload never uses, and would be the
    /// entry point if a part size ever became a setting.
    ///
    /// It still refuses a part size that cannot work at all — non-positive, or one that would need
    /// more than ``S3MultipartLimits/maximumPartCount`` parts.
    public init?(totalSize: Int64, partSize: Int64) {
        guard totalSize > 0, partSize > 0 else { return nil }
        guard Self.ceilingDivide(totalSize, partSize) <= Int64(S3MultipartLimits.maximumPartCount)
        else { return nil }
        self.totalSize = totalSize
        self.partSize = partSize
    }

    /// Whether a file of this size should be uploaded in parts at all.
    ///
    /// Asked before a plan is built, because the answer for a small file is "no plan" rather than
    /// "a plan with one part": a one-part multipart upload is three requests where one would do.
    public static func isWorthwhile(totalSize: Int64) -> Bool {
        totalSize > S3MultipartLimits.multipartThreshold
    }

    /// How many parts this file is cut into. Always at least 1, and never more than
    /// ``S3MultipartLimits/maximumPartCount``.
    public var partCount: Int {
        Int(Self.ceilingDivide(totalSize, partSize))
    }

    /// How many of this plan's parts are sent at once.
    ///
    /// Three bounds, and each is a different kind of limit: the policy
    /// (``S3MultipartLimits/preferredPartsInFlight``), the file (a two-part upload cannot run four
    /// in flight), and the disk (``S3MultipartLimits/stagingBudget`` divided by the part size,
    /// since every part in flight is staged as a temp file first). Never below 1, so a plan whose
    /// single part is larger than the whole budget still runs — one part at a time is what this
    /// code did before parallelism, not a state to refuse.
    public var partsInFlight: Int {
        let affordable = Int(max(1, S3MultipartLimits.stagingBudget / partSize))
        return min(S3MultipartLimits.preferredPartsInFlight, partCount, affordable)
    }

    /// The part numbers of each batch, in order — what the orchestration loops over.
    public var batches: [[Int]] {
        stride(from: 1, through: partCount, by: partsInFlight).map { first in
            Array(first...min(first + partsInFlight - 1, partCount))
        }
    }

    /// The byte range of part `number`, counting from 1.
    ///
    /// The last part is whatever is left, which is the one part allowed to be shorter than
    /// ``S3MultipartLimits/minimumPartSize`` — and for a file just over the threshold it usually is.
    /// Returns `nil` for a number outside the plan rather than trapping, so a caller that loses
    /// track produces a failed upload instead of a crash.
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

    private static func ceilingDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        divisor <= 0 ? 0 : (value + divisor - 1) / divisor
    }
}

/// One part that has been uploaded: its number and the ETag the server gave back.
///
/// The ETag is carried **exactly as received, quotes included**. S3 compares it byte for byte when
/// assembling the object, and the value it sends is quoted — so stripping the quotes to make the
/// value "clean" produces a `CompleteMultipartUpload` that fails with `InvalidPart` for every part.
public struct S3UploadedPart: Sendable, Equatable {
    public let number: Int
    public let etag: String

    public init(number: Int, etag: String) {
        self.number = number
        self.etag = etag
    }
}

/// One part on its way out: the slice to send and everything needed to address it.
///
/// Bundled for the same reason ``S3MultipartRequest`` is — a part upload names four things that
/// never vary independently, and spelling them out left the transport verb carrying six parameters
/// once it grew a progress hook.
public struct S3PartRequest: Sendable, Equatable {
    /// The temp file holding this part's bytes.
    public let localPath: String
    /// The object the finished upload will become.
    public let key: String
    /// The upload this part belongs to.
    public let uploadID: String
    /// The part number, counting from 1 — the order the completion manifest assembles in.
    public let number: Int

    public init(localPath: String, key: String, uploadID: String, number: Int) {
        self.localPath = localPath
        self.key = key
        self.uploadID = uploadID
        self.number = number
    }
}
