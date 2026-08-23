import Foundation

/// The four multipart argument builders, split out of `S3ProcessArguments.swift` when it reached
/// SwiftLint's 500-line ceiling (PLAN.md §M21 Slice 17).
///
/// Split by **concept** rather than shaved, which is the house rule for a type at the ceiling, and
/// this is the seam the backend already uses: `S3Backend+Multipart.swift` holds the verbs these
/// four requests serve, so the arguments now sit where their caller does. Nothing here changed in
/// the move.
public extension S3ProcessArguments {
    /// Open a multipart upload, whose answer carries the id every later request quotes.
    ///
    /// `--data-binary ""` for the same reason ``S3ProcessArguments/putEmptyObject(session:key:condition:)`` uses it: this POST
    /// has no body, and it is the one spelling that states its own emptiness with a real
    /// `Content-Length: 0` and a real payload digest rather than falling back to chunked framing.
    static func createMultipartUpload(session: S3Session, key: String) -> [String] {
        common(session: session) + configFromStandardInput
            + ["-X", "POST", "--data-binary", ""]
            + ["\(session.location.url(forKey: key))?uploads"]
    }

    /// Upload one part from a local slice file.
    ///
    /// `-T` again, so a part streams and memory stays flat whatever the part size — which is what
    /// lets the part size be chosen for request efficiency instead of being capped by RAM
    /// (``S3PartSlice`` argues why the slice is a file at all).
    ///
    /// **The upload id is percent-encoded**, and that is the continuation-token lesson applied
    /// before it can bite: an upload id is an opaque server-chosen token, so it is exactly the kind
    /// of value that round-trips raw right up until the day a server issues one containing a
    /// character that means something in a query string. The failure would be intermittent and
    /// per-server, which is the worst shape available.
    static func uploadPart(
        session: S3Session,
        key: String,
        uploadID: String,
        partNumber: Int,
        localPath: String
    ) -> [String] {
        let query = "partNumber=\(partNumber)&uploadId=\(S3Key.encodedForQuery(uploadID))"
        return common(session: session, showingProgress: true) + configFromStandardInput
            + ["--upload-file", localPath]
            + ["\(session.location.url(forKey: key))?\(query)"]
    }

    /// Close a multipart upload, handing the server the manifest of parts to assemble.
    ///
    /// The manifest travels as a **file** for the reason
    /// ``S3ProcessArguments/deleteObjects(session:bodyPath:contentMD5:)`` does: 10 000 parts of `<Part>` markup runs to
    /// hundreds of kilobytes, which is past `ARG_MAX`, so an inline body would work until somebody
    /// uploaded something large enough to need the parts. It carries no secret — part numbers and
    /// ETags — and stdin is holding the credential regardless.
    ///
    /// No `Content-MD5` here, unlike the batch delete: S3 requires that header on `DeleteObjects`
    /// and does not on this verb.
    ///
    /// **This is where a large upload's precondition rides** (PLAN.md §M21 Slice 19). The object
    /// appears only when this request is accepted, so a condition evaluated here decides whether a
    /// multipart upload is *published* — which is the same protection
    /// ``S3ProcessArguments/upload(session:key:localPath:condition:)`` gives a small one, and the
    /// reason ``S3ConditionalWrite/conditionWasSent`` is no longer `false` for every large file.
    ///
    /// Two measurements behind it, both against the endpoint that recomputes SigV4 by hand (a
    /// wrong-secret control refused in the same run):
    ///
    /// - **`curl` signs the header here too**, arriving as
    ///   `content-type;host;if-match;x-amz-content-sha256;x-amz-date`. That was worth measuring
    ///   rather than inheriting from the `PUT`: this canonical request differs in every field —
    ///   `POST`, a query string, and a **real** payload digest of the manifest rather than the
    ///   `UNSIGNED-PAYLOAD` a `-T` stream signs with — and it verified anyway.
    /// - **A refusal here cannot save the transfer, and that asymmetry is worth stating** because
    ///   the opposite is true one verb over. A conditional `PUT` is ended by the server's answer to
    ///   `Expect: 100-continue` before the body moves (64 MiB refused in 0.0009 s, Slice 17); every
    ///   part of a multipart upload has already been sent and paid for by the time this request is
    ///   made. So conditioning a large upload is protection, never an economy.
    static func completeMultipartUpload(
        session: S3Session,
        key: String,
        uploadID: String,
        bodyPath: String,
        condition: S3WriteCondition = .unconditional
    ) -> [String] {
        common(session: session) + configFromStandardInput
            + ["-X", "POST", "--data-binary", "@\(bodyPath)"]
            + ["-H", "Content-Type: application/xml"]
            + condition.headerArguments
            + ["\(session.location.url(forKey: key))?uploadId=\(S3Key.encodedForQuery(uploadID))"]
    }

    /// Abandon a multipart upload and release the parts already stored.
    ///
    /// **This is a bill, not tidiness.** S3 keeps the parts of an unfinished upload indefinitely and
    /// charges storage for them, and they are invisible to an ordinary listing — so an upload that
    /// dies without aborting leaves the user paying for bytes they cannot see and did not keep. It
    /// is the one request in this backend whose whole purpose is to run after something went wrong.
    static func abortMultipartUpload(
        session: S3Session,
        key: String,
        uploadID: String
    ) -> [String] {
        common(session: session) + configFromStandardInput
            + ["-X", "DELETE"]
            + ["\(session.location.url(forKey: key))?uploadId=\(S3Key.encodedForQuery(uploadID))"]
    }
}
