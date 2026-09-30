import Foundation

@testable import DirnexCore

/// ``FakeS3Transport``'s multipart verbs, split off when the double reached SwiftLint's
/// `type_body_length` — by concept, along the seam `S3Backend` and `S3ProcessArguments` are already
/// split on, rather than by shaving lines.
extension FakeS3Transport {
    /// Records the batch and then does exactly what the protocol's default does — send the parts
    /// one at a time — so every existing assertion over ``writes`` is untouched.
    func uploadParts(
        _ parts: [S3PartRequest],
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> [S3Response] {
        partBatches.append(parts.map(\.number))
        return try parts.map { part in
            if isCancelled() { throw CancellationError() }
            return try uploadPart(part, progress: progress, isCancelled: isCancelled)
        }
    }

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
}
