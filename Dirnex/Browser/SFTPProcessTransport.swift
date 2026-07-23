import DirnexCore
import Foundation

/// Drives the system `sftp` tool to satisfy an `SFTPBackend`'s operations — the non-hermetic half of
/// SFTP browse and transfer (PLAN.md §M5), mirroring `ArchiveMounter`/`SpotlightSearchRunner`. All
/// the parsing, escaping, argument assembly, and error classification live in `DirnexCore`
/// (`SFTPListingParser`, `SFTPBatchCommand`, `SFTPProcessArguments`, `SFTPTransportError.classify`);
/// this spawns `sftp -b -` and pipes one command in.
///
/// Key auth uses `-b -` (quiet, fail-fast, parseable) — `sftp`'s native non-interactive path.
/// Password auth can't use `-b` (it disables the prompt), so it runs `sftp` interactively and answers
/// the prompt through an `SSH_ASKPASS` helper (`SFTPProcessArguments` in core assembles the flags):
/// the password rides only in the child's environment (`SFTPAskpassHelper`), never on the command
/// line or on disk. Interactive mode means stdout carries `sftp>` echo lines (the parser skips them)
/// and a failed command exits zero (so this scans stderr with `detect`), and a wall-clock timeout
/// bounds a server that never closes the channel.
struct SFTPProcessTransport: SFTPTransport {
    let location: SFTPLocation
    /// How to authenticate — a key file, or a password fed via `SSH_ASKPASS`.
    let authentication: SFTPAuthentication
    /// The plaintext password for `.password` auth, resolved from the Keychain by the caller; `nil`
    /// for key auth. Held for the connection's lifetime so each spawned `sftp` can re-authenticate.
    var password: String?
    /// Seconds to wait for the connection before giving up — a dead host must not hang the pane.
    var connectTimeout: Int = 15
    /// Overall wall-clock bound (seconds) on a single *password* command, so an unresponsive or
    /// non-standard server can't hang the pane on a read that never ends (some servers hold the
    /// channel open after the reply). Generous enough for browse/metadata and small transfers; large
    /// password-auth transfers are a follow-up (alongside resume). Key auth keeps its unbounded,
    /// verified path.
    var passwordTimeout: Int = 30

    init(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        password: String? = nil,
        connectTimeout: Int = 15
    ) {
        self.location = location
        self.authentication = authentication
        self.password = password
        self.connectTimeout = connectTimeout
    }

    func listDirectory(_ remotePath: String) throws -> String {
        try run(batch: SFTPBatchCommand.list(remotePath))
    }

    // MARK: - Writes

    func makeDirectory(_ remotePath: String) throws {
        _ = try run(batch: SFTPBatchCommand.makeDirectory(remotePath))
    }

    func rename(_ source: String, to destination: String) throws {
        _ = try run(batch: SFTPBatchCommand.rename(source, to: destination))
    }

    func removeFile(_ remotePath: String) throws {
        _ = try run(batch: SFTPBatchCommand.removeFile(remotePath))
    }

    func removeDirectory(_ remotePath: String) throws {
        _ = try run(batch: SFTPBatchCommand.removeDirectory(remotePath))
    }

    func createSymbolicLink(_ remotePath: String, target: String) throws {
        _ = try run(batch: SFTPBatchCommand.createSymbolicLink(remotePath, target: target))
    }

    @discardableResult
    func download(_ remotePath: String, to localPath: String, resume: Bool) throws -> Int64 {
        _ = try run(batch: SFTPBatchCommand.download(remotePath, to: localPath, resume: resume))
        // `sftp get`/`get -a` leaves the whole file on disk, so its final size is the total
        // transferred; the backend derives the resumed remainder from the pre-existing length.
        return localFileSize(localPath)
    }

    @discardableResult
    func upload(_ localPath: String, to remotePath: String, resume: Bool) throws -> Int64 {
        _ = try run(batch: SFTPBatchCommand.upload(localPath, to: remotePath, resume: resume))
        // The local source's size is the remote file's total size after `put`/`put -a` — cheaper
        // and safer than re-statting the remote (which would cost another round trip).
        return localFileSize(localPath)
    }

    private func localFileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// The remote working (home) directory reported by `pwd`, to land in on connect. Doubles as a
    /// connection test: it fails fast (classified) when auth, the host, or the key is wrong.
    /// `tolerateChannelHold` lets it accept the reply from a server that holds the channel open
    /// afterwards (some appliances do) rather than timing out — safe here because `pwd`'s reply is a
    /// single line that has fully arrived by then.
    func resolveHomeDirectory() throws -> String {
        let output = try run(
            batch: SFTPBatchCommand.printWorkingDirectory,
            tolerateChannelHold: true
        )
        let marker = "Remote working directory: "
        for line in output.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: marker) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return "/"
    }

    // MARK: - Process

    /// Run one `sftp` batch command and return its stdout. `sftp` prints the `sftp>` prompt echo and
    /// the `ls` rows to stdout (the parser ignores the echo) and errors to stderr, exiting non-zero
    /// on a failed command — so a non-zero status is classified from stderr. Blocks on `sftp`; call
    /// it off the main thread.
    private func run(batch command: String, tolerateChannelHold: Bool = false) throws -> String {
        let isPassword: Bool
        if case .password = authentication { isPassword = true } else { isPassword = false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = SFTPProcessArguments.batch(
            location: location,
            authentication: authentication,
            connectTimeout: connectTimeout
        )
        if isPassword {
            process.environment = try passwordEnvironment()
        }

        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw SFTPTransportError.failure(String(
                localized: "Couldn’t launch sftp.",
                comment: "SFTP failure: the sftp binary could not be spawned."
            ))
        }

        // Feed the single batch command, then EOF so sftp runs it and exits.
        input.fileHandleForWriting.write(Data((command + "\n").utf8))
        try? input.fileHandleForWriting.close()

        // Drain both pipes on background queues — so neither can fill and deadlock the other on a
        // large listing — and join them through a group, which lets a password session bound its
        // wait (an unresponsive server must not hang the pane).
        var outputData = Data()
        var errorData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.dirnex.sftp.io", attributes: .concurrent)
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

        if isPassword, group.wait(timeout: .now() + .seconds(passwordTimeout)) == .timedOut {
            process.terminate() // SIGTERM closes the pipes so the drains unblock
            group.wait() // terminate closed the pipes, so the readers finish promptly
            if tolerateChannelHold {
                // The server replied but never closed the channel; the reply is complete, so hand it
                // back (only the single-line connect probe opts in — a multi-row listing must not be
                // read partially, hence the default-throw below).
                return String(bytes: outputData, encoding: .utf8) ?? ""
            }
            throw SFTPTransportError.failure(String(
                localized: "The SFTP server stopped responding.",
                comment: "SFTP failure: the server held the channel open past the timeout."
            ))
        }
        group.wait()
        process.waitUntilExit()

        let stderrText = String(bytes: errorData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw SFTPTransportError.classify(stderr: stderrText)
        }
        // An interactive (password) session exits zero even on a failed command, so its errors live
        // only in stderr — scan for them; key auth's `-b -` already fails non-zero above.
        if isPassword, let error = SFTPTransportError.detect(stderr: stderrText) {
            throw error
        }
        return String(bytes: outputData, encoding: .utf8) ?? ""
    }

    /// The `sftp` child's environment for password auth: the parent environment (so `HOME`, `PATH`,
    /// and the rest survive — `ssh` needs `HOME` to find `known_hosts`) plus the `SSH_ASKPASS`
    /// wiring that feeds the password without a TTY. `SSH_ASKPASS_REQUIRE=force` makes modern OpenSSH
    /// use the helper even with no controlling terminal.
    private func passwordEnvironment() throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = try SFTPAskpassHelper.scriptPath()
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment[SFTPAskpassHelper.passwordEnvironmentKey] = password ?? ""
        return environment
    }
}
