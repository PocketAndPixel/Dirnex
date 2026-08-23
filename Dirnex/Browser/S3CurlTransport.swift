import DirnexCore
import Foundation

/// Drives the system `curl` to satisfy an `S3Backend`'s requests — the non-hermetic half of S3
/// browsing (PLAN.md §M21), mirroring `FTPCurlTransport`. Every decision lives in `DirnexCore`
/// (`S3ProcessArguments`, `S3WriteOut`, `S3ListingParser`, `S3ServiceError`); this spawns the
/// process, feeds the secret in, and hands the raw answer back.
///
/// Three things it owns that the core cannot:
///
/// - **The secret access key never touches `argv` or the disk.** It goes to `curl`'s stdin as a
///   `-K -` config file, exactly as the FTP password does. Verified end-to-end rather than argued:
///   a fake key delivered this way comes back `InvalidAccessKeyId` from real AWS — the key was
///   looked up, so a well-formed signature reached the service — where the same request unsigned
///   answers something else entirely.
/// - **Both pipes are drained concurrently and the wait is bounded**, the two-pipe deadlock lesson
///   the `sftp` and FTP transports already carry (docs/NOTES.md). A bucket listing is easily large
///   enough to fill one.
/// - **The exit code decides only whether a server was reached.** This is the inverse of FTP's rule
///   and it is the whole reason S3 gets its own transport rather than a shared one: `curl` exits 0
///   for a missing key, a denied bucket, a bad signature and a wrong region alike, so the *status*
///   from the write-out is the classification and a nonzero exit is only consulted when there is no
///   status at all. That rule also absorbs `--fail`'s exit 22 on a refused transfer for free — the
///   response reached us, it just said no.
struct S3CurlTransport: S3Transport {
    let location: S3Location
    /// The secret access key, resolved from the Keychain by the caller and held for the
    /// connection's lifetime — each `curl` invocation re-signs, since HTTP keeps no session.
    let secretAccessKey: String
    var connectTimeout: Int = 15
    /// Wall-clock bound for a metadata request. Generous enough for a listing page over a slow
    /// link, tight enough that a dead endpoint doesn't hang the pane.
    var metadataTimeout: Int = 30
    /// Wall-clock bound for a byte transfer, which may legitimately run for a long time.
    var transferTimeout: Int = 3600
    /// How many keys one `ListObjectsV2` asks for — S3's own maximum, and the only reason it is a
    /// property rather than the constant it was is that the page *loop* is otherwise unwatchable.
    ///
    /// `S3Backend` pages until the service stops handing back a continuation token, and the token
    /// it sends back has to be percent-encoded or AWS refuses the page (``S3ProcessArguments``).
    /// At 1000 that rule needs a folder of more than a thousand objects to exercise at all, so a
    /// live test either builds one every run or the rule goes unwatched — the same fork
    /// docs/NOTES.md records for M22's result cap, settled the same way. A smaller page makes the
    /// loop, the real tokens and their encoding reachable over a handful of objects; nothing in
    /// the app sets it.
    var pageSize: Int = 1000

    init(location: S3Location, secretAccessKey: String, connectTimeout: Int = 15) {
        self.location = location
        self.secretAccessKey = secretAccessKey
        self.connectTimeout = connectTimeout
    }

    // MARK: - Requests

    func listObjects(
        prefix: String,
        delimiter: String?,
        continuationToken: String?
    ) throws -> S3Response {
        try perform(S3ProcessArguments.list(
            session: session(maxTime: metadataTimeout),
            prefix: prefix,
            delimiter: delimiter,
            continuationToken: continuationToken,
            maxKeys: pageSize
        ))
    }

    func download(
        key: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        try perform(
            S3ProcessArguments.download(
                session: session(maxTime: transferTimeout),
                key: key,
                localPath: localPath,
                resume: resume
            ),
            watching: .destinationFile(path: localPath),
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func head(key: String) throws -> S3Response {
        try perform(S3ProcessArguments.head(session: session(maxTime: metadataTimeout), key: key))
    }

    // MARK: - Writes

    func upload(
        localPath: String,
        to key: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        try upload(
            localPath: localPath,
            to: key,
            condition: .unconditional,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// The conditional form is the real one and the plain one forwards to it, rather than the
    /// other way round.
    ///
    /// That direction is deliberate: it leaves exactly **one** place where the upload arguments are
    /// assembled, so a precondition cannot be lost by a caller reaching the older spelling. The
    /// protocol's default implementation exists to protect a transport that has *not* been taught
    /// this (it throws rather than writing unguarded); a transport that has must not carry a second
    /// argument builder for the same request, which is how the two would drift.
    func upload(
        localPath: String,
        to key: String,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        try perform(
            S3ProcessArguments.upload(
                session: session(maxTime: transferTimeout),
                key: key,
                localPath: localPath,
                condition: condition
            ),
            measuring: .upload,
            watching: .uploadMeter(totalBytes: Self.fileSize(localPath)),
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func putEmptyObject(key: String) throws -> S3Response {
        try putEmptyObject(key: key, condition: .unconditional)
    }

    func putEmptyObject(key: String, condition: S3WriteCondition) throws -> S3Response {
        try perform(
            S3ProcessArguments.putEmptyObject(
                session: session(maxTime: metadataTimeout),
                key: key,
                condition: condition
            ),
            measuring: .upload
        )
    }

    func copyObject(from sourceKey: String, to destinationKey: String) throws -> S3Response {
        // A server-side copy of a large object can take far longer than a metadata call, since S3
        // is moving the bytes even though this machine is not.
        try perform(
            S3ProcessArguments.copyObject(
                session: session(maxTime: transferTimeout),
                sourceKey: sourceKey,
                destinationKey: destinationKey
            ),
            measuring: .download
        )
    }

    /// The same request with another bucket in `x-amz-copy-source` — the cross-bucket copy the
    /// pane routes here when both ends share a key and a service
    /// (`S3Location.acceptsServerSideCopy(from:)`). Nothing else differs: one `PUT`, signed once,
    /// with this connection's credentials doing the reading.
    func copyObject(
        fromBucket sourceBucket: String,
        sourceKey: String,
        to destinationKey: String
    ) throws -> S3Response {
        try perform(
            S3ProcessArguments.copyObject(
                session: session(maxTime: transferTimeout),
                sourceBucket: sourceBucket,
                sourceKey: sourceKey,
                destinationKey: destinationKey
            ),
            measuring: .download
        )
    }

    func deleteObject(key: String) throws -> S3Response {
        try perform(
            S3ProcessArguments.deleteObject(session: session(maxTime: metadataTimeout), key: key),
            measuring: .download
        )
    }

    /// A batch delete, whose request document travels as a temp file.
    ///
    /// The file is what keeps the batch size a real 1000: a thousand long keys run past `ARG_MAX`
    /// inline, so an inline body would work until somebody's file names were long. It carries no
    /// secret — object keys, which the URL already exposes — and it is removed on every exit path,
    /// including the throwing ones.
    func deleteObjects(keys: [String]) throws -> S3Response {
        let body = S3DeleteBatch.document(keys: keys)
        let bodyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-s3-delete-\(UUID().uuidString).xml")
        do {
            try body.write(to: bodyPath, options: .atomic)
        } catch {
            throw S3ResponseError.transport(.other)
        }
        defer { try? FileManager.default.removeItem(at: bodyPath) }

        return try perform(
            S3ProcessArguments.deleteObjects(
                session: session(maxTime: transferTimeout),
                bodyPath: bodyPath.path,
                contentMD5: S3DeleteBatch.contentMD5(for: body)
            ),
            measuring: .download
        )
    }

    /// Reach the endpoint and come back with nothing to say — the connection test the connect flow
    /// runs before saving anything. Every failure that matters (bad key, denied bucket, wrong
    /// region, unreachable host) surfaces here as a response or a throw, classified.
    ///
    /// One page of the bucket root, so an empty bucket is a success rather than a "not found": the
    /// question is whether the credential reaches the bucket, not whether anything is in it.
    func probeConnection() throws -> S3Response {
        try listObjects(prefix: "", delimiter: "/", continuationToken: nil)
    }

    // MARK: - Process

    /// Internal rather than private so `S3CurlTransport+Multipart` can spawn its own requests —
    /// Swift's `private` does not cross files (docs/NOTES.md ▸ Lint ceilings and file splitting).
    func session(maxTime: Int) -> S3Session {
        S3Session(location: location, connectTimeout: connectTimeout, maxTime: maxTime)
    }

    /// The process plumbing, which this shares with the account-level bucket list — see
    /// ``S3CurlRunner`` for the three rules that live there.
    private var runner: S3CurlRunner {
        S3CurlRunner(
            accessKeyID: location.accessKeyID,
            secretAccessKey: secretAccessKey,
            fallbackTimeout: metadataTimeout
        )
    }

    func perform(
        _ arguments: [String],
        measuring direction: S3CurlRunner.Direction = .download,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> S3Response {
        try runner.perform(
            arguments,
            measuring: direction,
            watching: source,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// The size an upload is a percentage *of*. Zero for a file that cannot be read, which reads as
    /// "no estimate available" — the transfer still runs and still reports its exact count at the
    /// end, it simply has nothing to draw a moving bar from.
    static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }
}
