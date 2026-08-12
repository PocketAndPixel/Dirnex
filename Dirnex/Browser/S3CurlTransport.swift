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
            continuationToken: continuationToken
        ))
    }

    func download(key: String, to localPath: String, resume: Bool) throws -> S3Response {
        try perform(S3ProcessArguments.download(
            session: session(maxTime: transferTimeout),
            key: key,
            localPath: localPath,
            resume: resume
        ))
    }

    func head(key: String) throws -> S3Response {
        try perform(S3ProcessArguments.head(session: session(maxTime: metadataTimeout), key: key))
    }

    // MARK: - Writes

    func upload(localPath: String, to key: String) throws -> S3Response {
        try perform(
            S3ProcessArguments.upload(
                session: session(maxTime: transferTimeout),
                key: key,
                localPath: localPath
            ),
            measuring: .upload
        )
    }

    func putEmptyObject(key: String) throws -> S3Response {
        try perform(
            S3ProcessArguments.putEmptyObject(
                session: session(maxTime: metadataTimeout),
                key: key
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

    // MARK: - Multipart

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
        localPath: String,
        to key: String,
        uploadID: String,
        partNumber: Int
    ) throws -> S3Response {
        try perform(
            S3ProcessArguments.uploadPart(
                session: session(maxTime: transferTimeout),
                key: key,
                uploadID: uploadID,
                partNumber: partNumber,
                localPath: localPath
            ),
            measuring: .upload
        )
    }

    /// Close the upload, with the manifest travelling as a temp file.
    ///
    /// A file rather than an inline body for the same reason the batch delete uses one: 10 000
    /// parts of `<Part>` markup runs past `ARG_MAX`, so an inline manifest would work right up to
    /// the file sizes multipart exists for. It carries no secret — part numbers and ETags — and is
    /// removed on every exit path, the throwing ones included.
    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart]
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
                bodyPath: bodyPath.path
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

    private func session(maxTime: Int) -> S3Session {
        S3Session(location: location, connectTimeout: connectTimeout, maxTime: maxTime)
    }

    /// Which counter an invocation's `bytesTransferred` should come from.
    ///
    /// Named by the caller rather than inferred from whichever number is non-zero, because a
    /// *refused* upload has both: the whole file went out, and the `<Error>` document came back.
    private enum Direction {
        case download
        case upload
    }

    /// Run one invocation and turn it into the answer the backend classifies.
    ///
    /// The status is read from the labelled write-out on stderr rather than from the exit code, and
    /// a status of 0 — `curl`'s own `000`, printed when nothing answered — is the only thing that
    /// makes this a transport failure. Everything else is a response, including the ones the server
    /// refused.
    private func perform(
        _ arguments: [String],
        measuring direction: Direction = .download
    ) throws -> S3Response {
        let result = try run(arguments)
        let fields = S3WriteOut.parse(stderr: result.standardError)
        guard fields.status != 0 else {
            throw S3ResponseError.transport(.classify(curlExit: result.exitCode))
        }
        return S3Response(
            status: fields.status,
            body: result.standardOutput,
            bucketRegion: fields.bucketRegion,
            contentLength: fields.contentLength,
            bytesTransferred: direction == .upload ? fields.bytesUploaded : fields.bytesDownloaded,
            etag: fields.etag
        )
    }

    private struct RunResult {
        let standardOutput: Data
        let standardError: String
        let exitCode: Int32
    }

    /// Spawn `curl` with the credential on stdin, drain both pipes concurrently, and bound the
    /// wait. Blocks; call it off the main thread — the backend is only ever driven by the operation
    /// engine or the panel's background list.
    private func run(_ arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments

        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw S3ResponseError.transport(.other)
        }

        // The secret goes in here and nowhere else — not in `arguments`, not on disk.
        let config = S3ConfigFile.credentials(
            accessKeyID: location.accessKeyID,
            secretAccessKey: secretAccessKey
        )
        input.fileHandleForWriting.write(Data(config.utf8))
        try? input.fileHandleForWriting.close()

        // Drain both pipes on background queues so neither can fill and deadlock the other, and
        // join them through a group so the wait can be bounded.
        let drained = Drained()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.dirnex.s3.io", attributes: .concurrent)
        group.enter()
        ioQueue.async {
            drained.standardOutput = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        ioQueue.async {
            drained.standardError = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // `curl`'s own `--max-time` should fire first; this is the backstop for a process that is
        // wedged rather than merely slow, so it is deliberately looser than the flag.
        let budget = curlMaxTime(in: arguments) + 30
        if group.wait(timeout: .now() + .seconds(budget)) == .timedOut {
            process.terminate() // SIGTERM closes the pipes so the drains unblock
            group.wait()
            throw S3ResponseError.transport(.operationTimedOut)
        }
        process.waitUntilExit()

        return RunResult(
            standardOutput: drained.standardOutput,
            standardError: String(bytes: drained.standardError, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// The two drained streams, in a reference box so the concurrent readers write into shared
    /// storage rather than into captured `var`s. Safe by the group: each field has exactly one
    /// writer, and nothing reads either until both drains have joined.
    private final class Drained: @unchecked Sendable {
        var standardOutput = Data()
        var standardError = Data()
    }

    /// The `--max-time` value already in the arguments, so the backstop is always derived from what
    /// `curl` was actually told rather than from a second, drifting constant.
    private func curlMaxTime(in arguments: [String]) -> Int {
        guard let index = arguments.firstIndex(of: "--max-time"),
              index + 1 < arguments.count,
              let value = Int(arguments[index + 1]) else { return metadataTimeout }
        return value
    }
}
