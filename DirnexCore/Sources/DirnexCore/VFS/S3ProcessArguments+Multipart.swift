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
    static func completeMultipartUpload(
        session: S3Session,
        key: String,
        uploadID: String,
        bodyPath: String
    ) -> [String] {
        common(session: session) + configFromStandardInput
            + ["-X", "POST", "--data-binary", "@\(bodyPath)"]
            + ["-H", "Content-Type: application/xml"]
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

    /// Copy one object to another key **inside the same bucket**, server-side.
    ///
    /// This is the rename primitive, and the reason a rename costs no local bandwidth: the bytes
    /// never leave S3. `curl` signs the `x-amz-copy-source` header itself — measured on the wire,
    /// it arrives in `SignedHeaders` as `host;x-amz-content-sha256;x-amz-copy-source;x-amz-date` —
    /// which matters because S3 requires every `x-amz-*` header to be signed and would otherwise
    /// refuse the request.
    ///
    /// What `curl` does **not** do is encode the value: the header is passed through byte for byte
    /// (probed with spaces and `+` in the source key, both of which arrived exactly as written). So
    /// the encoding is this builder's, and it uses the same path rule the URL does — S3 reads
    /// `x-amz-copy-source` as an encoded path, so a raw `+` or `#` in a key would name a different
    /// object than the one being renamed.
}
