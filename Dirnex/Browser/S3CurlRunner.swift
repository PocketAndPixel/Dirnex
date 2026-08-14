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

    /// What to watch while a transfer runs, so it can report where it has got to.
    ///
    /// The two directions have genuinely different observables, which is why this is an enum rather
    /// than one mechanism with a flag:
    ///
    /// - A **download** writes a file on this machine, so its size is the byte count, exactly, for
    ///   free, and with no change to the invocation's own flags.
    /// - An **upload** changes nothing locally. `curl`'s percentage meter is the only thing that
    ///   knows, which is why the upload arguments stop passing `-s` (``CurlProgressMeter``).
    ///
    /// `.none` is every metadata request: one round trip, nothing to report on the way.
    enum ProgressSource {
        case none
        case destinationFile(path: String)
        case uploadMeter(totalBytes: Int64)
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
        watching source: ProgressSource = .none,
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

    private struct RunResult {
        let standardOutput: Data
        let standardError: String
        let exitCode: Int32
    }

    /// Spawn `curl` with the credential on stdin, drain both pipes concurrently, and bound the
    /// wait. Blocks; call it off the main thread.
    private func run(
        _ arguments: [String],
        watching source: ProgressSource,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> RunResult {
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
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey
        )
        input.fileHandleForWriting.write(Data(config.utf8))
        try? input.fileHandleForWriting.close()

        // Drain both pipes on background queues so neither can fill and deadlock the other, and
        // join them through a group so the wait can be bounded.
        let drained = Drained()
        let meter = LiveMeter()
        let group = DispatchGroup()
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
                if let text = String(bytes: chunk, encoding: .utf8) { meter.consume(text) }
            }
            group.leave()
        }

        // `curl`'s own `--max-time` should fire first; this is the backstop for a process that is
        // wedged rather than merely slow, so it is deliberately looser than the flag.
        let budget = curlMaxTime(in: arguments) + 30
        var reporter = ProgressReporter(source: source, meter: meter)
        switch ProcessWaiting.wait(
            for: group,
            deadline: .now() + .seconds(budget),
            isCancelled: isCancelled,
            onPoll: { reporter.report(to: progress) }
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

    /// The progress meter, written by the stderr drain and read by the polling thread.
    ///
    /// Unlike ``Drained`` this one is read *while* it is being written — that is the whole point of
    /// it — so it carries a lock rather than resting on the group's join.
    private final class LiveMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var meter = CurlProgressMeter()

        func consume(_ text: String) {
            lock.lock()
            defer { lock.unlock() }
            meter.consume(text)
        }

        func bytesTransferred(ofTotal total: Int64) -> Int64? {
            lock.lock()
            defer { lock.unlock() }
            return meter.bytesTransferred(ofTotal: total)
        }
    }

    /// Turns whichever observable the caller named into the **deltas** `VFSBackend.copyFile` wants.
    ///
    /// It only ever reports forward. A download's file can legitimately shrink — a fresh (rather
    /// than resumed) download truncates whatever partial was there — and an estimate that went
    /// backwards would make the queue's byte tally, which only adds, wrong for the rest of the job.
    private struct ProgressReporter {
        let source: ProgressSource
        let meter: LiveMeter
        /// The destination's size when the process was spawned: for a resume, bytes that are
        /// already the user's and must not be counted again.
        private var baseline: Int64?
        private var lastSeen: Int64 = 0
        private var reported: Int64 = 0

        init(source: ProgressSource, meter: LiveMeter) {
            self.source = source
            self.meter = meter
            if case let .destinationFile(path) = source { baseline = Self.fileSize(path) }
        }

        mutating func report(to progress: (Int64) -> Void) {
            guard let moved = movedSoFar(), moved > reported else { return }
            let delta = moved - reported
            reported = moved
            progress(delta)
        }

        private mutating func movedSoFar() -> Int64? {
            switch source {
            case .none:
                return nil
            case let .destinationFile(path):
                let size = Self.fileSize(path)
                // Smaller than last time means `curl` truncated a partial it is not resuming from,
                // so the bytes it is writing now are all new.
                if size < lastSeen { baseline = 0 }
                lastSeen = size
                return max(0, size - (baseline ?? 0))
            case let .uploadMeter(totalBytes):
                return meter.bytesTransferred(ofTotal: totalBytes)
            }
        }

        private static func fileSize(_ path: String) -> Int64 {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int64 else { return 0 }
            return size
        }
    }

    /// The `--max-time` value already in the arguments, so the backstop is always derived from what
    /// `curl` was actually told rather than from a second, drifting constant.
    private func curlMaxTime(in arguments: [String]) -> Int {
        guard let index = arguments.firstIndex(of: "--max-time"),
              index + 1 < arguments.count,
              let value = Int(arguments[index + 1]) else { return fallbackTimeout }
        return value
    }
}
