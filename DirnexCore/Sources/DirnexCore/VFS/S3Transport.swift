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
    func download(key: String, to localPath: String, resume: Bool) throws -> S3Response

    /// One object's metadata. The size arrives in ``S3Response/contentLength``.
    func head(key: String) throws -> S3Response

    /// Upload a local file to `key`, streaming it rather than reading it into memory.
    func upload(localPath: String, to key: String) throws -> S3Response

    /// Write a zero-byte object at `key` — the folder marker, and an empty file.
    func putEmptyObject(key: String) throws -> S3Response

    /// Copy one object to another key inside this bucket, server-side. The bytes never travel.
    func copyObject(from sourceKey: String, to destinationKey: String) throws -> S3Response

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
    func uploadPart(
        localPath: String,
        to key: String,
        uploadID: String,
        partNumber: Int
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

    /// Abandon a multipart upload and release its stored parts — which S3 bills for until something
    /// removes them.
    func abortMultipartUpload(key: String, uploadID: String) throws -> S3Response
}
