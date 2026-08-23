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
    /// measured 2026-08-14 (docs/NOTES.md ▸ curl for S3).
    private(set) var cancelledTransfers: [String] = []
    private(set) var headKeys: [String] = []
    private(set) var writes: [Write] = []

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
        for delta in streamedProgress { progress(delta) }
        return downloadResponse
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

    // MARK: - Multipart

    func createMultipartUpload(key: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.createMultipart(key))
        return createMultipartResponse
    }

    func uploadPart(
        _ part: S3PartRequest,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        if isCancelled() { cancelledTransfers.append(part.key); throw CancellationError() }
        // Recorded before the response is chosen, so a test can assert on the slice file the
        // backend actually produced — including that it existed at the moment of the call.
        sliceSizes.append(sizeOfFile(part.localPath))
        // Capped at the slice, which is a real constraint rather than tidiness: a part's meter is a
        // percentage *of that part*, so it cannot report more than the slice holds. An uncapped
        // double would let a test "pass" on arithmetic the wire can never produce — and the short
        // final part is exactly where that would hide.
        var remaining = sizeOfFile(part.localPath)
        for delta in streamedProgress where remaining > 0 {
            let capped = min(delta, remaining)
            remaining -= capped
            progress(capped)
        }
        writes.append(
            .uploadPart(
                PartUpload(
                    localPath: part.localPath,
                    key: part.key,
                    uploadID: part.uploadID,
                    partNumber: part.number
                )
            )
        )
        let index = part.number - 1
        guard index < uploadPartResponses.count else {
            return S3Response(status: 200, etag: "\"etag-part-\(part.number)\"")
        }
        return uploadPartResponses[index]
    }

    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart]
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.completeMultipart(key: key, uploadID: uploadID, parts: parts))
        return completeMultipartResponse
    }

    /// The completion is where a *large* upload's precondition rides, so the condition it was given
    /// is recorded on the same list the two small-file verbs use — a large save-back that quietly
    /// dropped its header would otherwise leave `writes` looking perfectly correct.
    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart],
        condition: S3WriteCondition
    ) throws -> S3Response {
        conditions.append(condition)
        return try completeMultipartUpload(key: key, uploadID: uploadID, parts: parts)
    }

    func abortMultipartUpload(key: String, uploadID: String) throws -> S3Response {
        writes.append(.abortMultipart(key: key, uploadID: uploadID))
        if abortThrows { throw S3ResponseError.transport(.other) }
        return S3Response(status: 204)
    }

    /// The size of each slice at the moment its part was uploaded — how a test proves the backend
    /// cut the ranges the plan describes without reaching into the temp directory afterwards, by
    /// which time the slice is (correctly) gone.
    private(set) var sliceSizes: [Int64] = []

    private func sizeOfFile(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) as? Int64 ?? -1
    }
}

extension S3Response {
    /// A 200 carrying `xml`.
    static func ok(_ xml: String) -> S3Response {
        S3Response(status: 200, body: Data(xml.utf8))
    }
}
