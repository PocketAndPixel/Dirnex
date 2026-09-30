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
    /// Resolves the name to dial once per connection — the Bonjour fallback that lets a bare `nas`
    /// reach a server, and the record that keeps an mDNS name from costing five seconds a request.
    let dialer: HostDialer
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
        connectTimeout: Int = 15,
        dialer: HostDialer? = nil
    ) {
        self.location = location
        self.authentication = authentication
        self.password = password
        self.trustedPublicKey = trustedPublicKey
        self.connectTimeout = connectTimeout
        self.dialer = dialer ?? HostDialer(host: location.host)
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

    /// Create an empty file, preferring `APPE` and falling back to `STOR`.
    ///
    /// The order is what the two measurements ask for, and neither is optional.
    /// `APPE` leaves an already-present file untouched, so it is the one that keeps a lost race
    /// against `createFile`'s `stat` from truncating somebody's document; `STOR` is the one every
    /// server offers, and a server that grants it while refusing `APPE` answers exit 25 / 550 —
    /// measured 2026-08-23 by withdrawing exactly the append permission from a real server, with
    /// `STOR` still succeeding on the same connection.
    ///
    /// The fallback is safe to run blind. It is only ever reached for a name `createFile` has
    /// already found free, and every *other* reason `APPE` could fail — a missing parent, a
    /// read-only directory — fails `STOR` identically, so a retry costs one round trip and reports
    /// the second failure rather than masking anything.
    func createEmptyFile(_ remotePath: String) throws {
        let scratch = try EmptyUploadFile()
        defer { scratch.remove() }
        do {
            try uploadEmpty(scratch.path, to: remotePath, append: true)
        } catch {
            try uploadEmpty(scratch.path, to: remotePath, append: false)
        }
    }

    private func uploadEmpty(_ localPath: String, to remotePath: String, append: Bool) throws {
        _ = try runWithTLSRetry(timeout: metadataTimeout) { session in
            FTPProcessArguments.createFile(
                session: session,
                localPath: localPath,
                remotePath: remotePath,
                append: append
            )
        }
    }

    /// `RNFR` and `RNTO` are a *pair*: the server holds the pending rename between them, so they
    /// must travel on one connection. `curl` sends each `-Q` in order on the same connection, which
    /// is exactly what makes this expressible without a session.
    func rename(_ source: String, to destination: String) throws {
        try quote(try FTPQuoteCommand.rename(source, to: destination), near: parentOf(source))
    }

    // MARK: - Metadata carry (PLAN.md §M25 Slice 2)

    /// What an FTP account can be asked before anything has been refused. There is no preserve flag
    /// on this wire, so both are extensions the server need not implement — `SITE CHMOD` is by
    /// definition per-server, and `MFMT` is RFC 3659 rather than RFC 959.
    ///
    /// `MFMT` is the one thing FTP has that SFTP does not: an **exact, UTC-anchored** modification
    /// time, round-tripped live against the local truth on a host at +0300 so a zone error could not
    /// have hidden. The coarse, year-less, zone-less stamp FTP is known for belongs to `LIST`, not
    /// to the protocol.
    var metadataCapabilities: RemoteMetadataCapabilities { .ftp }

    /// Apply metadata steps in **their own invocation**, after the transfer.
    ///
    /// Measured 2026-08-28 against a real server, and it is the reason this is not folded into the
    /// upload: a quote command sent alongside the transfer is refused as `curl` **exit 21**, which
    /// fails the whole invocation *after* the bytes have landed — 16 bytes up, exit 21, a successful
    /// upload reported as a failed copy. `curl`'s continue-on-failure prefix avoids that and costs
    /// the attribution, since `%{http_code}` reports only the last reply. On its own the answer is
    /// exact: exit 21 with reply **500** is a verb this server does not have, **550** is that file's
    /// own problem, and `FTPTransportError.classify` already reads the difference.
    ///
    /// A refusal is **answered, not thrown**: the bytes are there and the file is right, so a server
    /// that will not keep a mode has not failed the copy.
    func applyMetadata(
        _ steps: [RemoteMetadataStep],
        to remotePath: String
    ) throws -> [RemoteMetadataRefusal] {
        let commands = try FTPQuoteCommand.metadataSteps(steps, on: remotePath)
        guard !commands.isEmpty else { return [] }
        do {
            try quote(commands, near: parentOf(remotePath))
            return []
        } catch let error as FTPTransportError {
            guard let refusal = Self.metadataRefusal(from: error) else { throw error }
            return [refusal]
        }
    }

    /// Read a refused quote command as the two answers that need different treatment, or `nil` when
    /// the failure was not about the command at all — a dropped connection or a refused login is the
    /// transfer's problem and must keep travelling as one.
    ///
    /// The split is the reply code's, which is why the core grew
    /// ``FTPTransportError/commandNotImplemented`` for it: reply **500** is a verb this server does
    /// not have — true of every file, so it latches — while **550** is that file's own problem and
    /// says nothing about the next one. Collapsed together, a carry would either stop attempting a
    /// verb the server honours or never learn about one it lacks.
    private static func metadataRefusal(from error: FTPTransportError) -> RemoteMetadataRefusal? {
        switch error {
        case .commandNotImplemented:
            return .verbUnimplemented("")
        case let .failure(text):
            return .itemRefused(text)
        case .notFound, .permissionDenied:
            return .itemRefused("")
        default:
            return nil
        }
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
    ///
    /// Progress comes from the **destination file**, not from `curl`: it is a local file that grows,
    /// so its size is exact and free, and this invocation's flags are left exactly as they were.
    @discardableResult
    func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let result = try runWithTLSRetry(
            timeout: transferTimeout,
            watching: .destinationFile(path: localPath),
            progress: progress,
            isCancelled: isCancelled
        ) { session in
            FTPProcessArguments.download(
                session: session,
                remotePath: remotePath,
                localPath: localPath,
                resume: resume
            )
        }
        return transferredBytes(from: result.standardOutput)
    }

    /// Progress comes from `curl`'s percentage meter, which the upload arguments stop suppressing
    /// (`-S` rather than `-sS`) precisely so it can be read: an upload changes nothing on this
    /// machine, so there is no local observable to watch instead.
    @discardableResult
    func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        // The total the meter's percentage is applied to is the *source's* size, which is exact
        // here; the meter's own `Total` column is rounded for display.
        let result = try runWithTLSRetry(
            timeout: transferTimeout,
            watching: .uploadMeter(totalBytes: localFileSize(localPath)),
            progress: progress,
            isCancelled: isCancelled
        ) { session in
            FTPProcessArguments.upload(
                session: session,
                localPath: localPath,
                remotePath: remotePath,
                resume: resume
            )
        }
        return transferredBytes(from: result.standardOutput)
    }

    private func localFileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
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
}
