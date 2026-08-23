import Foundation

@testable import DirnexCore

/// A fake ``S3Transport``, fed the bytes real buckets sent.
///
/// It hands out queued list responses in order, which is what makes the pagination loop testable:
/// the loop's job is to ask again with the token it was given, and a queue is the only double that
/// can tell a correct second request from a repeated first one.
final class FakeS3Transport: S3Transport, @unchecked Sendable {
    struct ListRequest: Equatable {
        let prefix: String
        let delimiter: String?
        let continuationToken: String?
    }

    struct Download: Equatable {
        let key: String
        let localPath: String
        let resume: Bool
    }

    struct Upload: Equatable {
        let localPath: String
        let key: String
    }

    struct Copy: Equatable {
        let sourceKey: String
        let destinationKey: String
    }

    /// Every write the backend made, in order — one list rather than several, because the *order*
    /// is what several of these tests are about: a rename that deleted before it copied, or a
    /// folder delete that removed the marker before its contents, would pass a per-verb tally.
    struct PartUpload: Equatable {
        let localPath: String
        let key: String
        let uploadID: String
        let partNumber: Int
    }

    enum Write: Equatable {
        case upload(Upload)
        case putEmpty(String)
        case copy(Copy)
        /// A copy whose source is in another bucket — recorded as its own case rather than as a
        /// `copy` with a field, so an assertion about the *same-bucket* verb cannot be satisfied by
        /// a cross-bucket request that happens to carry the right keys.
        case copyAcrossBuckets(sourceBucket: String, Copy)
        case delete(String)
        case deleteBatch([String])
        case createMultipart(String)
        case uploadPart(PartUpload)
        case completeMultipart(key: String, uploadID: String, parts: [S3UploadedPart])
        case abortMultipart(key: String, uploadID: String)
    }

    /// Handed out in order, one per `listObjects` call. The last one repeats once exhausted, so a
    /// test that means to exercise a bounded loop cannot accidentally run out of fixtures.
    var listPages: [S3Response] = []
    var headResponse = S3Response(status: 404)
    var downloadResponse = S3Response(status: 200)
    /// The answer every write verb gives, unless a batch answer is queued below.
    var writeResponse = S3Response(status: 200)
    /// Handed out in order, one per `deleteObjects` call, so a partial-failure body can be aimed at
    /// a particular batch. Falls back to ``writeResponse`` once exhausted.
    var deleteBatchResponses: [S3Response] = []
    /// Thrown by every verb when set — the "the request never reached a server" half.
    var thrownError: S3ResponseError?

    /// The object a segmented download serves its ranges out of. `nil` is an empty object, which
    /// only a test that does not care about the bytes should leave it as.
    var objectBytes: Data?
    /// Answers a `Range` request with the **whole** object under a 200 — the S3-compatible endpoint
    /// that does not honour ranges, which the backend has to notice and route around.
    var ignoresRanges = false
    /// Handed out in order, one per segment of a run. Falls back to a 206 carrying the range's own
    /// length, so a test aiming a refusal at segment 2 says only that.
    var segmentResponses: [S3Response] = []
    /// Every segmented download the backend asked for, in call order. The *requests* rather than
    /// their numbers, because the paths are what makes the cleanup assertable exactly: a test can
    /// ask whether the files this run was given still exist, rather than scanning a temp directory
    /// it shares with every other test in the process.
    private(set) var segmentRequests: [[S3DownloadSegment]] = []
    /// The segment numbers of each run — the only place the difference between one stream and
    /// several is visible at all.
    var segmentRuns: [[Int]] { segmentRequests.map { $0.map(\.number) } }

    /// The part numbers of each **batch** the backend handed over, in call order.
    ///
    /// Recorded beside ``writes`` rather than inside it, exactly as ``conditions`` is and for the
    /// same reason: the two answer different questions. `writes` is *what was uploaded*, and a
    /// sequential loop and a parallel batch produce identical entries there — which is the point,
    /// since the parts are the same parts. This is *how many went at once*, which is the only place
    /// the difference is visible at all.
    var partBatches: [[Int]] = []

    /// Every precondition that reached the transport, in call order.
    ///
    /// Recorded beside ``writes`` rather than inside it so no existing assertion has to change —
    /// and because the two answer different questions: `writes` is *what was asked for*, this is
    /// *what it was guarded with*. A verb that quietly dropped its condition would leave `writes`
    /// looking perfectly correct, which is exactly the failure ``S3WriteCondition`` exists to
    /// prevent, so it needs a record of its own to be visible at all.
    var conditions: [S3WriteCondition] = []

    /// Deltas each byte-moving verb reports before it answers — what a real transport streams off
    /// `curl`'s meter or the destination file's growth while the transfer runs.
    ///
    /// Empty by default, which is the *old* behavior (one report at the end) and keeps every test
    /// that is not about progress unchanged. A test that sets it is exercising the reconciliation:
    /// what arrives mid-transfer is a rounded estimate, so the caller has to end on the exact count
    /// rather than on the sum of the estimates.
    var streamedProgress: [Int64] = []

    /// The answer to `CreateMultipartUpload`. A real `InitiateMultipartUploadResult` by default, so
    /// a test only overrides it when the *opening* is what it is about.
    var createMultipartResponse = S3Response.ok(S3Fixtures.initiateMultipart)
    /// Handed out in order, one per part. Falls back to a 200 carrying a synthetic ETag once
    /// exhausted, so a test aiming a failure at part 3 says only that.
    var uploadPartResponses: [S3Response] = []
    var completeMultipartResponse = S3Response.ok(S3Fixtures.completeMultipart)
    /// Set to make the abort itself fail, which must never replace the error that provoked it.
    var abortThrows = false

    private(set) var listRequests: [ListRequest] = []
    private(set) var downloads: [Download] = []
    /// Transfers this fake was asked to abandon — the record that makes the cancellation rule
    /// assertable at all. A real transport polls `isCancelled` *while the bytes move*, which a
    /// headless double cannot reproduce; what it can pin is that the backend hands the flag down to
    /// the transfer verb instead of only checking it at the file boundary, which is exactly the gap
    /// measured 2026-08-14 (docs/NOTES.md ▸ curl for S3). Internal setter for the reason ``writes``
    /// has one: one of the verbs that fills it lives in a companion file.
    var cancelledTransfers: [String] = []
    private(set) var headKeys: [String] = []
    /// Internal setter rather than `private(set)`: the multipart verbs live in a companion
    /// file, and Swift's `private` does not cross files (docs/NOTES.md ▸ file splitting).
    var writes: [Write] = []

    func listObjects(
        prefix: String,
        delimiter: String?,
        continuationToken: String?
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        listRequests.append(
            ListRequest(prefix: prefix, delimiter: delimiter, continuationToken: continuationToken)
        )
        guard !listPages.isEmpty else { return S3Response(status: 200) }
        let index = min(listRequests.count - 1, listPages.count - 1)
        return listPages[index]
    }

    func download(
        key: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        // A real transport polls this *while the bytes move*; a fake can only record that it was
        // offered the chance, which is the half a headless test can pin.
        if isCancelled() { cancelledTransfers.append(key); throw CancellationError() }
        downloads.append(Download(key: key, localPath: localPath, resume: resume))
        // Writes the object when one is set, so a test about *which route ran* can also check that
        // the route it fell back to produced the file. Left alone when it is not, which is every
        // test that predates segmented downloads.
        if let objectBytes { try? objectBytes.write(to: URL(fileURLWithPath: localPath)) }
        for delta in streamedProgress { progress(delta) }
        return downloadResponse
    }

    /// Serve each range out of ``objectBytes`` into the file the segment names, exactly as a real
    /// `curl` writes one — which is what lets the assembly, and the bytes it produces, be asserted
    /// with no network.
    ///
    /// The two ways an endpoint can be *unhelpful* are switchable rather than hard-coded, because
    /// each drives a different branch of the backend: ``segmentResponses`` aims a refusal at a
    /// particular segment, and ``ignoresRanges`` reproduces a server that answers a `Range` request
    /// with the whole object under a 200 — a success, and not the thing that was asked for.
    func downloadSegments(
        _ segments: [S3DownloadSegment],
        of key: String,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3SegmentedDownload {
        if let thrownError { throw thrownError }
        if isCancelled() { cancelledTransfers.append(key); throw CancellationError() }
        segmentRequests.append(segments)
        let object = objectBytes ?? Data()
        return .segments(segments.enumerated().map { index, segment in
            let served = ignoresRanges ? object : Self.slice(object, segment.range)
            // A refused section creates no file at all — `--fail` is what makes that true on the
            // wire, and a double that wrote one anyway would let a broken assembly look correct.
            let response = index < segmentResponses.count
                ? segmentResponses[index]
                : S3Response(
                    status: ignoresRanges ? 200 : 206,
                    bytesTransferred: Int64(served.count)
                )
            if response.isSuccess {
                try? served.write(to: URL(fileURLWithPath: segment.localPath))
                progress(Int64(served.count))
            }
            return response
        })
    }

    private static func slice(_ object: Data, _ range: Range<Int64>) -> Data {
        let lower = min(Int(range.lowerBound), object.count)
        let upper = min(Int(range.upperBound), object.count)
        return object.subdata(in: lower..<upper)
    }

    func head(key: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        headKeys.append(key)
        return headResponse
    }

    // MARK: - Writes

    func upload(
        localPath: String,
        to key: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        if isCancelled() { cancelledTransfers.append(key); throw CancellationError() }
        writes.append(.upload(Upload(localPath: localPath, key: key)))
        for delta in streamedProgress { progress(delta) }
        return writeResponse
    }

    func putEmptyObject(key: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.putEmpty(key))
        return writeResponse
    }

    // MARK: - Conditional writes

    func upload(
        localPath: String,
        to key: String,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        conditions.append(condition)
        return try upload(
            localPath: localPath,
            to: key,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func putEmptyObject(key: String, condition: S3WriteCondition) throws -> S3Response {
        conditions.append(condition)
        return try putEmptyObject(key: key)
    }

    func copyObject(from sourceKey: String, to destinationKey: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.copy(Copy(sourceKey: sourceKey, destinationKey: destinationKey)))
        return writeResponse
    }

    func copyObject(
        fromBucket sourceBucket: String,
        sourceKey: String,
        to destinationKey: String
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.copyAcrossBuckets(
            sourceBucket: sourceBucket,
            Copy(sourceKey: sourceKey, destinationKey: destinationKey)
        ))
        return writeResponse
    }

    func deleteObject(key: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.delete(key))
        return writeResponse
    }

    func deleteObjects(keys: [String]) throws -> S3Response {
        if let thrownError { throw thrownError }
        let batchIndex = writes.filter {
            if case .deleteBatch = $0 { return true }
            return false
        }.count
        writes.append(.deleteBatch(keys))
        guard batchIndex < deleteBatchResponses.count else { return writeResponse }
        return deleteBatchResponses[batchIndex]
    }

    /// The size of each slice at the moment its part was uploaded — how a test proves the backend
    /// cut the ranges the plan describes without reaching into the temp directory afterwards, by
    /// which time the slice is (correctly) gone. Internal setter for the same reason ``writes`` has
    /// one: the verb that fills it lives in a companion file.
    var sliceSizes: [Int64] = []

    func sizeOfFile(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return -1 }
        return size
    }
}

extension S3Response {
    /// A 200 carrying `xml`.
    static func ok(_ xml: String) -> S3Response {
        S3Response(status: 200, body: Data(xml.utf8))
    }
}
