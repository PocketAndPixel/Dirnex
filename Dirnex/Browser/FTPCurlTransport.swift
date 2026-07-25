import DirnexCore
import Foundation

/// Drives the system `curl` to satisfy an `FTPBackend`'s operations — the non-hermetic half of FTP
/// and FTPS browse and transfer (PLAN.md §M13), mirroring `SFTPProcessTransport`. All the parsing,
/// argument assembly, escaping and error classification live in `DirnexCore`
/// (`FTPListingParser`, `FTPProcessArguments`, `FTPQuoteCommand`, `FTPTransportError.classify`);
/// this spawns the process and pipes the credential in.
///
/// Three things it is responsible for that the core cannot be:
///
/// - **The credential never touches `argv` or the disk.** It is written to `curl`'s stdin as a
///   `-K -` config file. `-u user:pass` would be readable by any `ps` on the machine.
/// - **Both pipes are drained concurrently and the wait is bounded.** The two-pipe deadlock lesson
///   from the `sftp` transport applies unchanged (docs/NOTES.md): a large listing fills one pipe
///   while the other is being read, and the process wedges.
/// - **The TLS 1.3 retry.** On the system `curl` 8.7.1 an FTPS data connection can come back empty
///   with exit 18; the workaround is TLS 1.2, and it is applied *only* after seeing that, so a
///   server that does 1.3 correctly is never downgraded. See `FTPTLSCompatibility.forceTLS12`.
struct FTPCurlTransport: FTPTransport {
    let location: FTPLocation
    let authentication: FTPAuthentication
    /// The plaintext password, resolved from the Keychain by the caller; ignored (and expected to be
    /// empty) for anonymous. Held for the connection's lifetime so each spawned `curl` can
    /// re-authenticate — FTP has no persistent session across invocations.
    var password: String
    /// The public key the user has explicitly trusted for this server, if any.
    var trustedPublicKey: String?
    var connectTimeout: Int = 15
    /// Wall-clock bound for a metadata command. Generous enough for a large listing over a slow
    /// link, tight enough that a dead server doesn't hang the pane.
    var metadataTimeout: Int = 30
    /// Wall-clock bound for a byte transfer, which may legitimately run for a long time.
    var transferTimeout: Int = 3600

    init(
        location: FTPLocation,
        authentication: FTPAuthentication,
        password: String = "",
        trustedPublicKey: String? = nil,
        connectTimeout: Int = 15
    ) {
        self.location = location
        self.authentication = authentication
        self.password = password
        self.trustedPublicKey = trustedPublicKey
        self.connectTimeout = connectTimeout
    }

    // MARK: - Reads

    func listDirectory(_ remotePath: String) throws -> String {
        try runWithTLSRetry { session in
            FTPProcessArguments.list(session: session, remotePath: remotePath)
        }.standardOutput
    }

    /// The exact size of one remote file, read from `-I`'s `Content-Length`. `curl` renders FTP's
    /// `SIZE`/`MDTM` replies in HTTP header shape, which is why this parses a header rather than a
    /// reply code.
    func fileSize(_ remotePath: String) throws -> Int64 {
        let result = try runWithTLSRetry { session in
            FTPProcessArguments.head(session: session, remotePath: remotePath)
        }
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.lowercased().hasPrefix("content-length:") else { continue }
            let value = text.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            if let size = Int64(value) { return size }
        }
        throw FTPTransportError.notFound
    }

    // MARK: - Writes

    func makeDirectory(_ remotePath: String) throws {
        try quote([try FTPQuoteCommand.makeDirectory(remotePath)], near: parentOf(remotePath))
    }

    func removeFile(_ remotePath: String) throws {
        try quote([try FTPQuoteCommand.removeFile(remotePath)], near: parentOf(remotePath))
    }

    func removeDirectory(_ remotePath: String) throws {
        try quote([try FTPQuoteCommand.removeDirectory(remotePath)], near: parentOf(remotePath))
    }

    /// `RNFR` and `RNTO` are a *pair*: the server holds the pending rename between them, so they
    /// must travel on one connection. `curl` sends each `-Q` in order on the same connection, which
    /// is exactly what makes this expressible without a session.
    func rename(_ source: String, to destination: String) throws {
        try quote(try FTPQuoteCommand.rename(source, to: destination), near: parentOf(source))
    }

    /// Run raw FTP commands. The URL only says where to connect and must not itself transfer, so it
    /// points at a directory — the *parent* of the item being acted on, which is guaranteed to exist
    /// (the item's own path may not, or may be about to stop existing).
    private func quote(_ commands: [String], near directory: String) throws {
        _ = try runWithTLSRetry(timeout: metadataTimeout) { session in
            FTPProcessArguments.quote(session: session, commands: commands, atPath: directory)
        }
    }

    private func parentOf(_ remotePath: String) -> String {
        let trimmed = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else { return "/" }
        return String(trimmed[..<slash])
    }

    // MARK: - Transfers

    /// `%{size_download}` is the bytes moved *by this run* — the remainder when resuming — so the
    /// backend gets its progress delta with no arithmetic. Verified live against a real server.
    @discardableResult
    func download(_ remotePath: String, to localPath: String, resume: Bool) throws -> Int64 {
        let result = try runWithTLSRetry(timeout: transferTimeout) { session in
            FTPProcessArguments.download(
                session: session,
                remotePath: remotePath,
                localPath: localPath,
                resume: resume
            )
        }
        return transferredBytes(from: result.standardOutput)
    }

    @discardableResult
    func upload(_ localPath: String, to remotePath: String, resume: Bool) throws -> Int64 {
        let result = try runWithTLSRetry(timeout: transferTimeout) { session in
            FTPProcessArguments.upload(
                session: session,
                localPath: localPath,
                remotePath: remotePath,
                resume: resume
            )
        }
        return transferredBytes(from: result.standardOutput)
    }

    /// The `-w` byte count, which is the whole of stdout for a transfer (the payload went to a file).
    private func transferredBytes(from output: String) -> Int64 {
        Int64(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - Certificate

    /// Fetch the server's certificate without trusting it, so the app can show the user what they
    /// are being asked to accept. Transfers nothing — it connects, prints the chain, and discards
    /// the body — which is why suppressing verification here is safe.
    func fetchCertificate() throws -> FTPCertificate {
        guard location.security.usesTLS else {
            throw FTPTransportError.failure("")
        }
        let result = try runWithTLSRetry(timeout: metadataTimeout) { session in
            FTPProcessArguments.certificateProbe(session: session)
        }
        guard let certificate = FTPCertificate.parse(curlCertificateBlock: result.standardOutput) else {
            throw FTPTransportError.failure(result.standardError)
        }
        return certificate
    }

    /// Reach the server and come back with nothing to say — the connection test the connect flow
    /// runs before saving anything. Any auth, host, TLS or trust failure surfaces here, classified.
    func probeConnection() throws {
        _ = try listDirectory("/")
    }

    // MARK: - Process

    private var session: FTPSession {
        FTPSession(
            location: location,
            trust: trustedPublicKey.map { .pinned(publicKey: $0) } ?? .systemDefault,
            tls: .negotiate,
            connectTimeout: connectTimeout,
            maxTime: metadataTimeout
        )
    }

    private struct RunResult {
        let standardOutput: String
        let standardError: String
    }

    /// Run `curl`, and on the one documented FTPS symptom — exit 18, a data connection that returned
    /// nothing — retry once pinned to TLS 1.2.
    ///
    /// The retry is what keeps the workaround from being a blanket downgrade. It fails in the quiet
    /// direction otherwise: an empty listing reads as an empty remote directory, so a user would see
    /// a folder they know has files in it appear empty, with no error anywhere.
    private func runWithTLSRetry(
        timeout: Int? = nil,
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
            return try run(arguments(base))
        } catch let error as CurlExit where error.code == 18 && location.security.usesTLS {
            let retry = base.with(tls: .forceTLS12)
            do {
                return try run(arguments(retry))
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
    private struct CurlExit: Error {
        let code: Int32
        let standardError: String
    }

    /// Spawn `curl` with the credential on stdin, drain both pipes concurrently, and bound the wait.
    /// Blocks; call it off the main thread — the backend is only ever driven by the operation engine
    /// or the panel's background list.
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
            throw FTPTransportError.failure(String(
                localized: "Couldn’t launch curl.",
                comment: "FTP failure: the curl binary could not be spawned."
            ))
        }

        // The credential goes in here and nowhere else — not in `arguments`, not on disk.
        let config = FTPConfigFile.credentials(for: location, password: password)
        input.fileHandleForWriting.write(Data(config.utf8))
        try? input.fileHandleForWriting.close()

        // Drain both pipes on background queues so neither can fill and deadlock the other, and
        // join them through a group so the wait can be bounded.
        var outputData = Data()
        var errorData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.dirnex.ftp.io", attributes: .concurrent)
        group.enter()
        ioQueue.async {
            outputData = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        ioQueue.async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // `curl`'s own `--max-time` should fire first; this is the backstop for a process that is
        // wedged rather than merely slow, so it is deliberately looser than the flag.
        let budget = curlMaxTime(in: arguments) + 30
        if group.wait(timeout: .now() + .seconds(budget)) == .timedOut {
            process.terminate() // SIGTERM closes the pipes so the drains unblock
            group.wait()
            throw FTPTransportError.timedOut
        }
        group.wait()
        process.waitUntilExit()

        let standardError = String(bytes: errorData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw CurlExit(code: process.terminationStatus, standardError: standardError)
        }
        return RunResult(
            standardOutput: String(bytes: outputData, encoding: .utf8) ?? "",
            standardError: standardError
        )
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
