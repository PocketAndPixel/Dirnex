import Foundation

/// Turning one finished `curl` run into the answer the backend classifies — or into the transport
/// failure it really was.
///
/// The labelled write-out says what the server answered; the exit code says whether the transfer
/// *finished*. This backend used to read the first alone, on the ground that `curl` exits 0 for
/// every S3 refusal (docs/NOTES.md ▸ curl for S3), and that ground is still true. What it missed is
/// the other direction: a status arrives with the response's first line, so a transfer that stops
/// after it still has one.
public extension S3WriteOut {
    /// Which counter a response's ``S3Response/bytesTransferred`` comes from.
    ///
    /// Named by the caller rather than inferred from whichever number is non-zero, because a
    /// *refused* upload has both: the whole file went out, and the `<Error>` document came back.
    enum Direction: Sendable {
        case download
        case upload
    }

    /// Whether one transfer's run is the server's answer, rather than a transfer that stopped.
    ///
    /// **A status is not enough to call it an answer.** Measured 2026-10-23 with `curl` 8.7.1, the
    /// shipped download arguments and `Tooling/fake-s3-endpoint.py`: a `GET` that ran out of
    /// `--max-time` part-way printed `s3-status=200`, exited **28**, and left 528 332 bytes of a
    /// 3 129 010-byte object under the destination's name. A connection closed mid-body is the same
    /// with exit 18, and a destination `curl` cannot write is exit 23 with a 200 and no file at all.
    /// Read by status alone, each one is a finished copy.
    ///
    /// So the exit code decides first. 0 is an answer. 22 is `--fail`'s refusal and an answer too,
    /// since the write-out still carries the 4xx or 5xx. Anything else is a transfer that stopped,
    /// whatever status it had seen by then. A status of 0 (`curl`'s `000`, nothing answered) is
    /// never an answer.
    ///
    /// The cost is in the safe direction: an upload the server stored and whose reply was then cut
    /// reads as failed, and the user copies again. The other way round, a sixth of a photo reads
    /// as a finished download.
    static func isAnswer(status: Int, exitCode: Int32) -> Bool {
        status != 0 && (exitCode == 0 || (exitCode == 22 && status >= 400))
    }

    /// One finished single-transfer run as the response the backend classifies, or the transport
    /// failure it was (``isAnswer(status:exitCode:)``).
    ///
    /// The process's exit code is the transfer's own here, since the run carried one transfer. A
    /// parallel run carries several, and each section reports its own
    /// (``S3SegmentWriteOut/response(forSegment:processExitCode:)``).
    static func response(
        exitCode: Int32,
        standardOutput: Data,
        standardError: String,
        measuring direction: Direction = .download
    ) throws -> S3Response {
        let fields = parse(stderr: standardError)
        guard isAnswer(status: fields.status, exitCode: exitCode) else {
            throw S3ResponseError.transport(.classify(curlExit: exitCode))
        }
        return S3Response(
            status: fields.status,
            body: standardOutput,
            bucketRegion: fields.bucketRegion,
            contentLength: fields.contentLength,
            bytesTransferred: direction == .upload ? fields.bytesUploaded : fields.bytesDownloaded,
            etag: fields.etag
        )
    }
}
