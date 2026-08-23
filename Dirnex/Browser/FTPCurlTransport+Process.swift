import DirnexCore
import Foundation

/// The process half of ``FTPCurlTransport``: spawning `curl`, feeding it the credential, draining
/// its two pipes without deadlocking, bounding the wait, and the one documented FTPS retry.
///
/// Split out when the transport reached SwiftLint's `type_body_length` on gaining progress
/// reporting — by concept rather than by shaving lines, which is the house rule: the verbs above say
/// *what* is asked of the server, and this says how a subprocess is run. It is the same seam
/// `S3CurlRunner` already sits on for the S3 side.
extension FTPCurlTransport {
    var session: FTPSession {
        FTPSession(
            location: location,
            trust: trustedPublicKey.map { .pinned(publicKey: $0) } ?? .systemDefault,
            tls: .negotiate,
            connectTimeout: connectTimeout,
            maxTime: metadataTimeout
        )
    }

    struct RunResult {
        let standardOutput: String
        let standardError: String
    }

    /// Run `curl`, and on the one documented FTPS symptom — exit 18, a data connection that returned
    /// nothing — retry once pinned to TLS 1.2.
    ///
    /// The retry is what keeps the workaround from being a blanket downgrade. It fails in the quiet
    /// direction otherwise: an empty listing reads as an empty remote directory, so a user would see
    /// a folder they know has files in it appear empty, with no error anywhere.
    func runWithTLSRetry(
        timeout: Int? = nil,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false },
        arguments: (FTPSession) -> [String]
    ) throws -> RunResult {
        var base = session
        if let timeout {
            base = FTPSession(
                location: location,
                trust: base.trust,
                tls: .negotiate,
                connectTimeout: connectTimeout,
                maxTime: timeout
            )
        }
        do {
            return try run(
                arguments(base), watching: source, progress: progress, isCancelled: isCancelled
            )
        } catch let error as CurlExit where error.code == 18 && location.security.usesTLS {
            let retry = base.with(tls: .forceTLS12)
            do {
                return try run(
                    arguments(retry), watching: source, progress: progress, isCancelled: isCancelled
                )
            } catch let retryError as CurlExit {
                throw FTPTransportError.classify(
                    exitCode: retryError.code,
                    stderr: retryError.standardError
                )
            }
        } catch let error as CurlExit {
            throw FTPTransportError.classify(exitCode: error.code, stderr: error.standardError)
        }
    }

    /// A nonzero `curl` exit, carried untranslated so the retry decision can be made on the code
    /// before it is classified into the shared vocabulary.
    struct CurlExit: Error {
        let code: Int32
        let standardError: String
    }

    /// Spawn `curl` with the credential on stdin, drain both pipes concurrently, and bound the wait.
    /// Blocks; call it off the main thread — the backend is only ever driven by the operation engine
    /// or the panel's background list.
    func run(
        _ arguments: [String],
        configuration: String? = nil,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
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
        // `waitUntilExit()`, which is a ≈71 ms poll paid once per listing (`ProcessWaiting`).
        let group = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: group)

        do {
            try process.run()
        } catch {
            throw FTPTransportError.failure(String(
                localized: "Couldn’t launch curl.",
                comment: "FTP failure: the curl binary could not be spawned."
            ))
        }

        // The credential goes in here and nowhere else — not in `arguments`, not on disk. A caller
        // that supplies its own configuration has already put it in — a parallel batch must, since
        // `curl` reads one option set per transfer and each section needs its own copy
        // (`FTPProcessArguments.downloadSegments`).
        let config = configuration ?? FTPConfigFile.credentials(for: location, password: password)
        input.fileHandleForWriting.write(Data(config.utf8))
        try? input.fileHandleForWriting.close()

        // Drain both pipes on background queues so neither can fill and deadlock the other, and
        // join them through a group so the wait can be bounded.
        let drained = Drained()
        let ioQueue = DispatchQueue(label: "com.dirnex.ftp.io", attributes: .concurrent)
        group.enter()
        ioQueue.async {
            drained.standardOutput = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        ioQueue.async {
            // Chunked rather than `readDataToEndOfFile`, so an upload's progress meter can be read
            // *while* it is being written. It drains just as continuously, which is the property
            // that matters — a reader that stops reading is the two-pipe deadlock.
            //
            // **`availableData`, never `read(upToCount:)`**: measured on the S3 twin, the latter
            // loops until it has the count asked for or EOF, so it hands the whole meter over after
            // the transfer it describes is finished — the silence this exists to end, reintroduced
            // one layer down and invisible to everything but a live run (docs/NOTES.md ▸ curl).
            let handle = errorPipe.fileHandleForReading
            while case let chunk = handle.availableData, !chunk.isEmpty {
                drained.standardError.append(chunk)
                // A read boundary can fall inside a multi-byte character, so this decode is allowed
                // to fail and be skipped: the authoritative bytes are the ones appended above, and
                // what is lost is one tick of an estimate.
                if let text = String(bytes: chunk, encoding: .utf8) { watch.consume(text) }
            }
            group.leave()
        }

        // `curl`'s own `--max-time` should fire first; this is the backstop for a process that is
        // wedged rather than merely slow, so it is deliberately looser than the flag.
        let budget = max(
            curlMaxTime(in: arguments),
            Self.curlMaxTime(inConfiguration: config)
        ) + 30
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
            throw FTPTransportError.timedOut
        case .cancelled:
            process.terminate()
            group.wait()
            throw CancellationError()
        }
        group.wait()

        // The *prose*, not the raw stream: with the meter let through for an upload, stderr also
        // carries the table (measured 2026-08-16 — a refused upload's stderr goes from 61 bytes to
        // 378), and this string is what `FTPTransportError.classify` scans for a reply code and
        // what `.failure` carries as the server's own words. Taken from the complete capture rather
        // than from the live reader, which skips any chunk whose UTF-8 decode fails at a read
        // boundary — a cost an estimate can absorb and a diagnosis cannot.
        let standardError = CurlProgressMeter.prose(
            in: String(bytes: drained.standardError, encoding: .utf8) ?? ""
        )
        guard process.terminationStatus == 0 else {
            throw CurlExit(code: process.terminationStatus, standardError: standardError)
        }
        return RunResult(
            standardOutput: String(bytes: drained.standardOutput, encoding: .utf8) ?? "",
            standardError: standardError
        )
    }

    /// The drained streams, in a reference box so the concurrent readers write into shared storage
    /// rather than into captured `var`s. Safe by the group: each field has exactly one writer, and
    /// nothing reads either until both drains have joined.
    final class Drained: @unchecked Sendable {
        var standardOutput = Data()
        var standardError = Data()
    }

    /// The `--max-time` value already in the arguments, so the backstop is always derived from what
    /// `curl` was actually told rather than from a second, drifting constant.
    func curlMaxTime(in arguments: [String]) -> Int {
        guard let index = arguments.firstIndex(of: "--max-time"),
              index + 1 < arguments.count,
              let value = Int(arguments[index + 1]) else { return metadataTimeout }
        return value
    }

    /// The same value when it rides in the **configuration** instead — a parallel batch puts every
    /// per-transfer option in its sections, so `argv` carries no `--max-time` at all and the
    /// backstop would otherwise fall back to the metadata timeout and kill a long download it was
    /// only ever meant to catch wedged. The same trap the S3 runner already documents.
    /// Internal rather than private so the rule can be asserted directly.
    static func curlMaxTime(inConfiguration configuration: String) -> Int {
        configuration.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "max-time" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.max() ?? 0
    }
}
