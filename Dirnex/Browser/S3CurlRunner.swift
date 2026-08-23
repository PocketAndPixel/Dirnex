import DirnexCore
import Foundation

/// Spawns one `curl` and turns its answer into an `S3Response` — the process plumbing every S3
/// request shares, whether or not it is about a bucket (PLAN.md §M21).
///
/// Extracted from `S3CurlTransport` when the account-level bucket list arrived, because that request
/// needs all of this and has no `S3Location` to hold: it is a *service* call, which is the whole
/// point of ``S3Account``. The alternative was a second copy of the two-pipe drain, and that is
/// precisely the code docs/NOTES.md records as subtle — a drain that fills deadlocks the process it
/// is reading, silently and only on large answers.
///
/// Three rules live here rather than in the core, because they are about the process rather than
/// about S3:
///
/// - **The secret access key never touches `argv` or the disk.** It goes to `curl`'s stdin as a
///   `-K -` config file, exactly as the FTP password does.
/// - **Both pipes are drained concurrently and the wait is bounded.**
/// - **The exit code decides only whether a server was reached.** The inverse of FTP's rule: `curl`
///   exits 0 for a missing key, a denied bucket, a bad signature and a wrong region alike, so the
///   *status* from the write-out is the classification and a nonzero exit is consulted only when
///   there is no status at all. That absorbs `--fail`'s exit 22 on a refused transfer for free —
///   the response arrived, it just said no.
struct S3CurlRunner: Sendable {
    /// The access key id — an identifier, and the config file's other half.
    let accessKeyID: String
    /// The secret access key, resolved from the Keychain by the caller and held for the
    /// connection's lifetime — each invocation re-signs, since HTTP keeps no session.
    let secretAccessKey: String
    /// The bound used when the arguments carry no `--max-time` of their own to derive one from.
    var fallbackTimeout: Int = 30

    /// Which counter an invocation's `bytesTransferred` should come from.
    ///
    /// Named by the caller rather than inferred from whichever number is non-zero, because a
    /// *refused* upload has both: the whole file went out, and the `<Error>` document came back.
    enum Direction {
        case download
        case upload
    }

    /// Run one invocation and turn it into the answer the caller classifies.
    ///
    /// A status of 0 — `curl`'s own `000`, printed when nothing answered — is the only thing that
    /// makes this a transport failure. Everything else is a response, including the refusals.
    /// `isCancelled` is polled while the process runs, so a caller's Stop reaches **inside** a
    /// transfer instead of being noticed after it. The default suits every metadata request: a
    /// listing or a `HEAD` is one round trip, over long before anyone could press anything.
    func perform(
        _ arguments: [String],
        measuring direction: Direction = .download,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> S3Response {
        let result = try run(
            arguments,
            watching: source,
            progress: progress,
            isCancelled: isCancelled
        )
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

    /// Run one invocation that carries **several** part uploads and answer for each of them, in
    /// the order they were given.
    ///
    /// The single-response `perform` cannot serve this: four sections print four statuses into one
    /// stream, so the answers are read out of the *indexed* write-out each section was given
    /// (``S3PartWriteOut``) rather than from one set of labels. Everything else is the same run —
    /// one process, both pipes drained, the wait bounded, one `terminate()` on cancel that stops
    /// every section at once, which is the whole reason a batch is one `curl` rather than several.
    ///
    /// A part with **no status at all** is a transport failure rather than a refusal: `curl` prints
    /// nothing for a section it never ran, which is what a bad argument or a terminated process
    /// looks like. A part that ran and was refused has a status, and is classified by the caller
    /// exactly as any other response is.
    ///
    /// The body is the whole invocation's stdout, handed to every part. It is only ever read for a
    /// part that failed (`serviceError(from:)` ignores it on success), and an `UploadPart` that
    /// succeeds answers with no body at all — so in the ordinary single-failure case it is exactly
    /// that part's `<Error>` document. Several failing parts in one batch share it, which costs the
    /// `<Code>` its attribution and not its accuracy: they are refused for the same reason.
    func performParts(
        _ invocation: S3ParallelInvocation,
        parts: [S3PartRequest],
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> [S3Response] {
        let lengths = Dictionary(
            uniqueKeysWithValues: parts.map { ($0.number, Self.fileSize($0.localPath)) }
        )
        let result = try run(
            invocation.arguments,
            configuration: invocation.configuration,
            watching: .uploadedParts(lengths: lengths),
            progress: progress,
            isCancelled: isCancelled
        )
        let reported = S3PartWriteOut.parse(stderr: result.standardError)
        return try parts.map { part in
            guard let fields = reported.fields(forPart: part.number) else {
                throw S3ResponseError.transport(.classify(curlExit: result.exitCode))
            }
            return S3Response(
                status: fields.status,
                body: result.standardOutput,
                bytesTransferred: fields.bytesUploaded,
                etag: fields.etag
            )
        }
    }

    /// Run one invocation that carries **several ranges of one object** and answer for each of
    /// them, in the order they were given (docs/HISTORY.md ▸ After M19).
    ///
    /// The upload batch's twin, and it differs in exactly one place: where progress comes from. A
    /// batch of uploads has only its own write-out lines to go on, while a batch of downloads is
    /// writing several files on this machine — so their combined size is the byte count, exact and
    /// arriving continuously rather than a segment at a time. Everything else is the same run: one
    /// process, both pipes drained, the wait bounded, one `terminate()` on cancel that stops every
    /// section at once.
    ///
    /// The body — this invocation's stdout — is deliberately **not** handed to the responses. Every
    /// section writes its own bytes to its own file with `--fail`, so a refused section creates no
    /// file and prints no document; stdout carries nothing worth attributing, and handing the same
    /// buffer to every segment would let one section's noise be read as another's `<Error>`.
    func performSegments(
        _ invocation: S3ParallelInvocation,
        segments: [S3DownloadSegment],
        totalBytes: Int64,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> [S3Response] {
        let result = try run(
            invocation.arguments,
            configuration: invocation.configuration,
            watching: .destinationFiles(
                paths: segments.map(\.localPath),
                totalBytes: totalBytes
            ),
            progress: progress,
            isCancelled: isCancelled
        )
        let reported = S3SegmentWriteOut.parse(stderr: result.standardError)
        return try segments.map { segment in
            guard let fields = reported.fields(forSegment: segment.number) else {
                throw S3ResponseError.transport(.classify(curlExit: result.exitCode))
            }
            return S3Response(status: fields.status, bytesTransferred: fields.bytesDownloaded)
        }
    }

    /// The size of a local file, or 0 when it cannot be read — a part whose length is unknown
    /// simply reports nothing, which is the same "no estimate available" the meter falls back to.
    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    private struct RunResult {
        let standardOutput: Data
        let standardError: String
        let exitCode: Int32
    }

    /// Spawn `curl` with the credential on stdin, drain both pipes concurrently, and bound the
    /// wait. Blocks; call it off the main thread.
    private func run(
        _ arguments: [String],
        configuration: String? = nil,
        watching source: TransferProgressWatch.Source,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments

        // Built **before** the child is spawned: a resumed `-C -` download continues into a file
        // that already holds bytes, and the watch's baseline has to be read while it is still
        // standing still, or part of what is already on disk is counted as this transfer's.
        let watch = TransferProgressWatch(source)

        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        // Joined before `run()`, and waited on below beside the two drains — never
        // `waitUntilExit()`, which is a ≈71 ms poll paid once per request (`ProcessWaiting`).
        let group = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: group)

        do {
            try process.run()
        } catch {
            throw S3ResponseError.transport(.other)
        }

        // The secret goes in here and nowhere else — not in `arguments`, not on disk. A caller
        // that supplies its own configuration has already put the credential in it — a parallel
        // batch must, since `curl` reads one option set per transfer and each section needs its own
        // (`S3ProcessArguments.uploadParts`).
        let config = configuration ?? S3ConfigFile.credentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey
        )
        input.fileHandleForWriting.write(Data(config.utf8))
        try? input.fileHandleForWriting.close()

        // Drain both pipes on background queues so neither can fill and deadlock the other, and
        // join them through a group so the wait can be bounded.
        let drained = Drained()
        let ioQueue = DispatchQueue(label: "com.dirnex.s3.io", attributes: .concurrent)
        group.enter()
        ioQueue.async {
            drained.standardOutput = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        ioQueue.async {
            // Chunked rather than `readDataToEndOfFile`, so the progress meter can be read *while*
            // it is being written. It drains just as continuously, which is the property that
            // matters — a reader that stops reading is the two-pipe deadlock.
            //
            // **`availableData`, never `read(upToCount:)`.** The obvious spelling is not chunked at
            // all: measured on a child writing three lines a second apart, `read(upToCount: 4096)`
            // returned once, at exit, holding all three — it loops until it has the count asked for
            // or EOF. Against `curl` that hands the whole meter over after the transfer is done,
            // which is *precisely* the silence this reader exists to end, and it fails invisibly:
            // every byte still arrives, so the response is classified correctly and only the
            // progress quietly never moves.
            let handle = errorPipe.fileHandleForReading
            while case let chunk = handle.availableData, !chunk.isEmpty {
                drained.standardError.append(chunk)
                // A read boundary can fall inside a multi-byte character, which is why this decode
                // is allowed to fail and be skipped. It costs nothing that matters: the meter is
                // pure ASCII, so only `curl`'s own prose can produce an undecodable chunk, and the
                // authoritative bytes are the ones appended above. What is skipped is one tick of
                // an estimate, never a byte of the answer.
                if let text = String(bytes: chunk, encoding: .utf8) { watch.consume(text) }
            }
            group.leave()
        }

        // `curl`'s own `--max-time` should fire first; this is the backstop for a process that is
        // wedged rather than merely slow, so it is deliberately looser than the flag.
        let budget = max(curlMaxTime(in: arguments), Self.curlMaxTime(inConfiguration: config)) + 30
        switch ProcessWaiting.wait(
            for: group,
            deadline: .now() + .seconds(budget),
            isCancelled: isCancelled,
            onPoll: { watch.report(to: progress) }
        ) {
        case .finished:
            break
        case .timedOut:
            process.terminate() // SIGTERM closes the pipes so the drains unblock
            group.wait()
            throw S3ResponseError.transport(.operationTimedOut)
        case .cancelled:
            process.terminate()
            group.wait()
            throw CancellationError()
        }

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
              let value = Int(arguments[index + 1]) else { return fallbackTimeout }
        return value
    }

    /// The same value when it rides in the **configuration** instead — a parallel batch puts every
    /// per-transfer option in its sections, so `argv` carries no `--max-time` at all and the
    /// backstop would otherwise fall back to the metadata timeout and kill a long upload it was
    /// only ever meant to catch wedged.
    /// Internal rather than private so the rule can be asserted directly: it is the difference
    /// between a bound that matches what `curl` was told and one that kills a long upload.
    static func curlMaxTime(inConfiguration configuration: String) -> Int {
        configuration.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "max-time" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.max() ?? 0
    }
}
