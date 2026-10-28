import DirnexCore
import Foundation

/// One `curl` run: spawned with an optional configuration on stdin, both pipes drained at once, the
/// wait bounded and a caller's Stop honoured — and nothing about what the run *meant*.
///
/// `FTPCurlTransport` and `S3CurlRunner` each carry this plumbing inside their own types, written
/// before there was a third protocol to share it with, and each turns the end of a run straight
/// into its own error vocabulary. WebDAV (PLAN.md §M32 Slice 3) gets it as a type with no protocol
/// in it: the caller hands the exit code and both streams to its own reader
/// (``WebDAVWriteOut/response(exitCode:standardOutput:standardError:)``), which is where the
/// decision about a run lives, in the core. The two older transports can move onto it without
/// changing what they decide.
///
/// The rules here are the ones docs/NOTES.md records as subtle, each paid for once already:
///
/// - **The configuration never touches `argv` or the disk.** It is written to stdin, for `-K -`,
///   and only when the caller has one; otherwise stdin is `/dev/null`.
/// - **Both pipes drain on serial queues of their own** (``ProcessWaiting/pipeQueue(_:qos:)``), so
///   a large listing cannot fill one pipe while the other is read, and a drain always starts even
///   while every cooperative thread is blocked waiting.
/// - **stderr is read in chunks with `availableData`**, never `read(upToCount:)`, so a download's
///   destination can be watched while it grows and the progress reaches the caller during the run.
/// - **The wait is bounded and polls Stop** (``ProcessWaiting``). `curl`'s own `--max-time` should
///   fire first; the backstop catches a process that is wedged rather than slow.
enum CurlProcess {
    /// What one finished run left behind.
    struct Result {
        let standardOutput: Data
        /// Decoded leniently: a byte that is not UTF-8 in `curl`'s prose must not cost the labelled
        /// lines after it, which are what the run is read by.
        let standardError: String
        let exitCode: Int32
    }

    /// A run that ended without an exit code worth reading.
    enum Failure: Error, Equatable {
        /// `/usr/bin/curl` could not be spawned.
        case launchFailed
        /// The backstop fired, and the process was terminated.
        case timedOut
    }

    /// Spawn `curl` with `arguments`, feed it `configuration` on stdin when there is one, and wait
    /// for it — at most `backstop` seconds. Blocks; call it off the main thread.
    ///
    /// Throws ``Failure`` when there is no run to read, and `CancellationError` when `isCancelled`
    /// answered `true` first. A nonzero exit is **not** thrown: what it means is the caller's
    /// reader's business.
    static func run(
        _ arguments: [String],
        configuration: String?,
        backstop: Int,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments

        // Built before the child is spawned, so a resumed download's baseline is read while the
        // file is still standing still (`TransferProgressWatch`).
        let watch = TransferProgressWatch(source)

        let input = configuration.map { _ in Pipe() }
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorPipe

        // Joined before `run()` and waited on beside the drains, never `waitUntilExit()`, which is
        // a ≈71 ms poll paid once per request (`ProcessWaiting`).
        let group = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: group)

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed
        }

        if let input, let configuration {
            input.fileHandleForWriting.write(Data(configuration.utf8))
            try? input.fileHandleForWriting.close()
        }

        let drained = Drained()
        let outputQueue = ProcessWaiting.pipeQueue("com.dirnex.curl.output")
        let errorQueue = ProcessWaiting.pipeQueue("com.dirnex.curl.errors")
        group.enter()
        outputQueue.async {
            drained.standardOutput = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        errorQueue.async {
            let handle = errorPipe.fileHandleForReading
            while case let chunk = handle.availableData, !chunk.isEmpty {
                drained.standardError.append(chunk)
                // A read boundary can split a character, so this decode may fail and be skipped:
                // what is lost is one tick of an estimate, never a byte of the answer.
                if let text = String(bytes: chunk, encoding: .utf8) { watch.consume(text) }
            }
            group.leave()
        }

        switch ProcessWaiting.wait(
            for: group,
            deadline: .now() + .seconds(backstop),
            isCancelled: isCancelled,
            onPoll: { watch.report(to: progress) }
        ) {
        case .finished:
            break
        case .timedOut:
            process.terminate() // SIGTERM closes the pipes so the drains unblock
            group.wait()
            throw Failure.timedOut
        case .cancelled:
            process.terminate()
            group.wait()
            throw CancellationError()
        }

        return Result(
            standardOutput: drained.standardOutput,
            standardError: SubprocessText.lossyUTF8(drained.standardError),
            exitCode: process.terminationStatus
        )
    }

    /// The backstop for `arguments`: the `--max-time` they carry plus thirty seconds, so `curl`'s
    /// own limit fires first and this only ever catches a process that stopped answering. A run
    /// with no `--max-time` takes `fallback`.
    static func backstop(for arguments: [String], fallback: Int) -> Int {
        guard let index = arguments.firstIndex(of: "--max-time"),
              index + 1 < arguments.count,
              let value = Int(arguments[index + 1]) else { return fallback + 30 }
        return value + 30
    }

    /// The drained streams, in a reference box so the two readers write into shared storage rather
    /// than into captured `var`s. Safe by the group: each field has one writer, and nothing reads
    /// either until both drains have joined.
    private final class Drained: @unchecked Sendable {
        var standardOutput = Data()
        var standardError = Data()
    }
}
