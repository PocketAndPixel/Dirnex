import Foundation

/// One HTTP answer from an S3 endpoint, in the shape the backend classifies.
///
/// The body is carried whether or not the request succeeded, because on a failure the body *is*
/// the diagnosis: S3 answers 404, 403 and 301 with an `<Error>` document naming which of the four
/// or five things that status can mean actually happened (``S3ServiceError``).
public struct S3Response: Sendable, Equatable {
    /// The HTTP status, or 0 when `curl` got no response at all.
    public let status: Int
    /// The response body — a `ListBucketResult`, an `<Error>` document, or empty for a HEAD.
    public let body: Data
    /// `x-amz-bucket-region`, when the server sent it.
    public let bucketRegion: String?
    /// `Content-Length`, the size a HEAD reports.
    public let contentLength: Int64?
    /// Bytes this invocation moved, for a transfer.
    public let bytesTransferred: Int64
    /// The `ETag` header, verbatim and quoted — an uploaded part's identity, which the completion
    /// manifest quotes back byte for byte.
    public let etag: String?

    public init(
        status: Int,
        body: Data = Data(),
        bucketRegion: String? = nil,
        contentLength: Int64? = nil,
        bytesTransferred: Int64 = 0,
        etag: String? = nil
    ) {
        self.status = status
        self.body = body
        self.bucketRegion = bucketRegion
        self.contentLength = contentLength
        self.bytesTransferred = bytesTransferred
        self.etag = etag
    }

    /// Whether the server said yes.
    ///
    /// The whole 2xx range, not `== 200`, and that is not defensive generality: a **resumed
    /// download answers 206** (measured against a real bucket 2026-08-12), so a rule keyed on 200
    /// would classify every correct resume as a failure — and only for the users whose transfer was
    /// interrupted once.
    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// The non-hermetic boundary beneath an ``S3Backend``: it issues signed HTTP requests and hands
/// back the raw answer for the backend to classify. Everything above it — key translation, the
/// pagination loop, listing parsing, the stat rule, error mapping — is pure and tested in
/// `DirnexCore`; the transport is where real network I/O lives, so it is injected (PLAN.md §2),
/// exactly as `FTPTransport` and `SFTPTransport` are.
///
/// The app supplies a `Process`-driven implementation over the system `curl`, which signs SigV4
/// natively. Tests supply a fake fed the bytes real buckets sent, so the backend is exercised
/// end-to-end with no network and no credentials.
///
/// A method throws only when the request never got an answer — ``S3ResponseError/transport(_:)``,
/// classified from `curl`'s exit code. **A refusal by the server is a returned value, not a
/// throw**, and that split is the whole point: `curl` exits 0 for a missing key, a denied bucket,
/// a bad signature and a wrong region alike, so a transport that threw on "failure" would have
/// nothing to throw on and every S3 error would read as success.
///
/// Every method is synchronous and may block on the network — the backend is always called off the
/// main thread by the operation engine and the panel's background list, never on it.
public protocol S3Transport: Sendable {
    /// One page of `ListObjectsV2` under `prefix`. `delimiter` is `/` for a directory listing and
    /// `nil` for a recursive sweep.
    func listObjects(
        prefix: String,
        delimiter: String?,
        continuationToken: String?
    ) throws -> S3Response

    /// Download one object to a local path, resuming from what is already there when `resume`.
    ///
    /// `isCancelled` is polled **while the bytes move** and is the only thing that can stop a
    /// transfer early — see ``upload(localPath:to:progress:isCancelled:)`` for why it is a parameter
    /// on the byte-moving verbs and on nothing else. `progress` rides with it for the same reason
    /// and on the same poll: it reports **deltas** as they land, so a transfer that runs for minutes
    /// is not one silent invocation that reports everything at the end.
    func download(
        key: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response

    /// One object's metadata. The size arrives in ``S3Response/contentLength``.
    func head(key: String) throws -> S3Response

    /// Upload a local file to `key`, streaming it rather than reading it into memory.
    ///
    /// **The three byte-moving verbs take `progress` and `isCancelled`, and the metadata verbs
    /// deliberately do not.** A transfer is one `curl` invocation that can run for an hour, so both
    /// a caller's Stop and its progress bar have to reach *inside* it; a listing or a `HEAD` is a
    /// round trip that is over before anyone could press anything, and giving those either
    /// parameter would suggest a responsiveness they cannot use. Both halves were measured against
    /// the real endpoint rather than assumed: without `isCancelled`, Stop on a 16-second download
    /// returned after the full 16 seconds with the whole object downloaded and then discarded; and
    /// without `progress`, a 29 MB upload reported its bytes once, **99 seconds** after it started
    /// (docs/NOTES.md ▸ curl for S3).
    ///
    /// `progress` is called with a **delta**, matching `VFSBackend.copyFile`'s contract, and it is
    /// an *estimate* while the bytes are moving: it comes from `curl`'s own percentage meter, whose
    /// resolution is one per cent. The exact figure is the write-out's, and it arrives in
    /// ``S3Response/bytesTransferred`` — so a caller that wants a total that is right to the byte
    /// reconciles against that at the end rather than summing the deltas.
    func upload(
        localPath: String,
        to key: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response

    /// The same upload, with a precondition the *server* evaluates (``S3WriteCondition``).
    ///
    /// A separate requirement rather than a defaulted parameter on the one above, because a
    /// protocol requirement cannot carry a default and the alternative — widening the existing
    /// verb — would break every conformance in one edit for a capability most callers never ask
    /// for. The default implementation below is what keeps this additive.
    func upload(
        localPath: String,
        to key: String,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response

    /// Write a zero-byte object at `key` — the folder marker, and an empty file.
    func putEmptyObject(key: String) throws -> S3Response

    /// The same zero-byte write, with a precondition the server evaluates.
    func putEmptyObject(key: String, condition: S3WriteCondition) throws -> S3Response

    /// Copy one object to another key inside this bucket, server-side. The bytes never travel.
    func copyObject(from sourceKey: String, to destinationKey: String) throws -> S3Response

    /// Copy one object into this bucket from **another bucket on the same service**, server-side.
    /// The bytes never travel here either — S3 reads them itself, named by `x-amz-copy-source`.
    ///
    /// Additive rather than a widened ``copyObject(from:to:)``, for the reason ``upload`` states
    /// above: a protocol requirement cannot carry a default, so widening the existing verb would
    /// rewrite every conformance for a capability most callers never reach.
    ///
    /// **The default refuses instead of forwarding**, which is the same choice
    /// ``S3WriteConditionUnsupported`` makes and for a sharper reason. A transport that ignored
    /// `sourceBucket` would build the header from its *own* bucket and copy a different object
    /// under the right name, exit 0, reporting success — the one failure a caller cannot detect.
    /// Which bucket a copy reads is not a capability to degrade; it is the request.
    func copyObject(
        fromBucket sourceBucket: String,
        sourceKey: String,
        to destinationKey: String
    ) throws -> S3Response

    /// Delete one object. S3's delete is idempotent, so a key that is not there still answers 204.
    func deleteObject(key: String) throws -> S3Response

    /// Delete a batch of at most ``S3DeleteBatch/maximumKeys`` objects in one request.
    ///
    /// The response body is a `DeleteResult` and **is** the outcome: a 200 can carry per-key
    /// `<Error>` rows, so the status alone does not say the keys are gone (``S3DeleteResult``).
    /// Serializing the request document and its `Content-MD5` is the transport's, since the body
    /// travels as a file — a size decision argued in ``S3ProcessArguments/deleteObjects(session:bodyPath:contentMD5:)``.
    func deleteObjects(keys: [String]) throws -> S3Response

    /// Open a multipart upload. The answer carries the id every later request quotes.
    func createMultipartUpload(key: String) throws -> S3Response

    /// Upload one part from a local slice file. The part's ETag comes back in
    /// ``S3Response/etag``.
    ///
    /// `progress` reports within the part, which is what keeps the bar moving on a plan whose parts
    /// are 16 MiB and whose file may be hundreds of them.
    func uploadPart(
        _ part: S3PartRequest,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response

    /// Close a multipart upload with the manifest of parts to assemble.
    ///
    /// The response body **is** part of the outcome: a completion can answer 200 carrying an
    /// `<Error>` document, so the status alone does not say the object exists
    /// (``S3MultipartDocument/completionFailure(from:status:)``). Serializing the manifest and
    /// giving it a file to travel in is the transport's, as it is for a batch delete.
    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart]
    ) throws -> S3Response

    /// The same completion, with a precondition the server evaluates (``S3WriteCondition``).
    ///
    /// This is the multipart half of the conditional write, and the request it hangs on is the one
    /// that *publishes* the object — so a large save-back gets the protection a small one has had
    /// since Slice 17. A separate requirement with a throwing default, for the same reason
    /// ``upload(localPath:to:condition:progress:isCancelled:)`` is: a protocol requirement cannot
    /// carry a default parameter, and a transport that has not been taught this must refuse rather
    /// than publish an object the caller believes was guarded.
    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart],
        condition: S3WriteCondition
    ) throws -> S3Response

    /// Abandon a multipart upload and release its stored parts — which S3 bills for until something
    /// removes them.
    func abortMultipartUpload(key: String, uploadID: String) throws -> S3Response
}

/// The additive half of ``S3WriteCondition``: a transport that predates conditional writes keeps
/// compiling and keeps working, and can never silently write *without* the precondition it was
/// handed.
///
/// The forwarding is the whole design. An unconditional request is passed straight through to the
/// verb that already exists, so nothing changes for the callers that ask for nothing; a real
/// condition **throws**, because dropping it is the one outcome that would be worse than not
/// having the feature — the caller would believe the server had guarded a write it never saw a
/// precondition for. That is the same reasoning ``S3WriteConditionUnsupported`` carries and the
/// same failure direction this project keeps naming: quiet, plausible, and wrong.
public extension S3Transport {
    func upload(
        localPath: String,
        to key: String,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        guard !condition.isConditional else { throw S3WriteConditionUnsupported(key: key) }
        return try upload(
            localPath: localPath,
            to: key,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func putEmptyObject(key: String, condition: S3WriteCondition) throws -> S3Response {
        guard !condition.isConditional else { throw S3WriteConditionUnsupported(key: key) }
        return try putEmptyObject(key: key)
    }

    func copyObject(
        fromBucket sourceBucket: String,
        sourceKey: String,
        to destinationKey: String
    ) throws -> S3Response {
        throw S3CrossBucketCopyUnsupported(sourceBucket: sourceBucket, sourceKey: sourceKey)
    }

    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart],
        condition: S3WriteCondition
    ) throws -> S3Response {
        guard !condition.isConditional else { throw S3WriteConditionUnsupported(key: key) }
        return try completeMultipartUpload(key: key, uploadID: uploadID, parts: parts)
    }
}

/// Thrown by ``S3Transport``'s default cross-bucket copy: this transport cannot name another
/// bucket as a copy source, so it will not guess at one (``S3Transport/copyObject(fromBucket:sourceKey:to:)``).
///
/// Unreachable in the shipped app — `S3CurlTransport` implements the verb — and it is what a fake
/// in a test, or a transport somebody adds later, meets first. It is a distinct type rather than a
/// `VFSError` because nobody reads it: the pane's routing backend takes any failure of a
/// server-side copy as "the service will not do this one" and stages the bytes through this
/// machine instead, which is the route that needs no cooperation from either end.
public struct S3CrossBucketCopyUnsupported: Error, Sendable, Equatable {
    public let sourceBucket: String
    public let sourceKey: String

    public init(sourceBucket: String, sourceKey: String) {
        self.sourceBucket = sourceBucket
        self.sourceKey = sourceKey
    }
}
