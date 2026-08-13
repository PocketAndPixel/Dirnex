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
    func perform(
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
    /// wait. Blocks; call it off the main thread.
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
            accessKeyID: accessKeyID,
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
              let value = Int(arguments[index + 1]) else { return fallbackTimeout }
        return value
    }
}
