import DirnexCore
import Foundation

/// The multipart verbs, split out when the transport reached SwiftLint's `type_body_length`
/// ceiling — by concept rather than by shaving lines, and along the seam `S3ProcessArguments` and
/// `S3Backend` are already split on.
///
/// They are one cluster and read as one: an upload id threaded through create → part → complete,
/// with an abort that exists to run after something has gone wrong. Nothing here decides anything
/// — every argument list is `S3ProcessArguments+Multipart`'s, and the plan that says whether a file
/// is worth splitting at all is `S3MultipartPlan`'s.
extension S3CurlTransport {
    func createMultipartUpload(key: String) throws -> S3Response {
        try perform(
            S3ProcessArguments.createMultipartUpload(
                session: session(maxTime: metadataTimeout),
                key: key
            ),
            measuring: .download
        )
    }

    func uploadPart(
        _ part: S3PartRequest,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        try perform(
            S3ProcessArguments.uploadPart(
                session: session(maxTime: transferTimeout),
                key: part.key,
                uploadID: part.uploadID,
                partNumber: part.number,
                localPath: part.localPath
            ),
            measuring: .upload,
            // The slice, not the whole file: this invocation's meter is a percentage of the part it
            // was handed, and the orchestration above tops each part up to its exact length.
            watching: .uploadMeter(totalBytes: Self.fileSize(part.localPath)),
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// Close the upload, with the manifest travelling as a temp file.
    ///
    /// A file rather than an inline body for the same reason the batch delete uses one: 10 000
    /// parts of `<Part>` markup runs past `ARG_MAX`, so an inline manifest would work right up to
    /// the file sizes multipart exists for. It carries no secret — part numbers and ETags — and is
    /// removed on every exit path, the throwing ones included.
    /// Several parts at once, in one `curl` — what makes a large upload finish in a fraction of
    /// the time (`S3ProcessArguments.uploadParts`, which argues the flags and what was measured).
    ///
    /// The credential goes into the **configuration** here rather than being added by the runner,
    /// because `curl` reads one option set per transfer and each section needs its own copy. It
    /// still never touches `argv`, which is the property that matters.
    func uploadParts(
        _ parts: [S3PartRequest],
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> [S3Response] {
        guard !parts.isEmpty else { return [] }
        let invocation = S3ProcessArguments.uploadParts(
            session: session(maxTime: transferTimeout),
            parts: parts,
            credentials: S3ConfigFile.credentials(
                accessKeyID: location.accessKeyID,
                secretAccessKey: secretAccessKey
            )
        )
        return try runner.performParts(
            invocation,
            parts: parts,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart]
    ) throws -> S3Response {
        try completeMultipartUpload(
            key: key,
            uploadID: uploadID,
            parts: parts,
            condition: .unconditional
        )
    }

    /// The conditional form is the real one and the plain one forwards to it, as it does for
    /// `upload` and for the same reason: one place where these arguments are assembled, so a
    /// precondition cannot be lost by a caller reaching the older spelling.
    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart],
        condition: S3WriteCondition
    ) throws -> S3Response {
        let body = S3MultipartDocument.manifest(parts: parts)
        let bodyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-s3-complete-\(UUID().uuidString).xml")
        do {
            try body.write(to: bodyPath, options: .atomic)
        } catch {
            throw S3ResponseError.transport(.other)
        }
        defer { try? FileManager.default.removeItem(at: bodyPath) }

        return try perform(
            S3ProcessArguments.completeMultipartUpload(
                session: session(maxTime: transferTimeout),
                key: key,
                uploadID: uploadID,
                bodyPath: bodyPath.path,
                condition: condition
            ),
            measuring: .download
        )
    }

    func abortMultipartUpload(key: String, uploadID: String) throws -> S3Response {
        try perform(
            S3ProcessArguments.abortMultipartUpload(
                session: session(maxTime: metadataTimeout),
                key: key,
                uploadID: uploadID
            ),
            measuring: .download
        )
    }
}
