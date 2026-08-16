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

    /// Progress is the destination file's own growth, which is exact and costs nothing — and is the
    /// only thing available, since `sftp` prints no meter a spawned process can read
    /// (`SFTPTransport.upload`).
    @discardableResult
    func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        _ = try run(
            batch: SFTPBatchCommand.download(remotePath, to: localPath, resume: resume),
            watching: .destinationFile(path: localPath),
            progress: progress,
            isCancelled: isCancelled
        )
        // `sftp get`/`get -a` leaves the whole file on disk, so its final size is the total
        // transferred; the backend derives the resumed remainder from the pre-existing length.
        return localFileSize(localPath)
    }

    /// **`progress` is never called here**, and that is `sftp`'s doing rather than an omission: an
    /// upload changes nothing on this machine to watch, and OpenSSH draws its progress meter only
    /// for a foreground process group on a controlling terminal — probed six ways over a 1 GiB
    /// transfer, including with the `progress` batch command explicitly enabling it, and it printed
    /// nothing every time. The backend reports the whole count when this returns. The alternative,
    /// polling the *remote* size, is a fresh connection and handshake per tick on a transport with
    /// no session (`SFTPTransport.upload` carries the measurement).
    @discardableResult
    func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        _ = try run(
            batch: SFTPBatchCommand.upload(localPath, to: remotePath, resume: resume),
            isCancelled: isCancelled
        )
        // The local source's size is the remote file's total size after `put`/`put -a` — cheaper
        // and safer than re-statting the remote (which would cost another round trip).
        return localFileSize(localPath)
    }

    /// Run one command on the server's own shell over an SSH **exec** channel — the search
    /// shortcut's route (PLAN.md §M22 Slice 4), and the one verb here that does not speak SFTP.
    ///
    /// `nil` means *the command could not be asked at all* — `ssh` would not launch, or the server
    /// held the channel past the timeout. It does **not** mean "this account has no exec channel",
    /// and that distinction is the probe's finding rather than a preference: an account confined to
    /// the `sftp` subsystem answers an exec request with an ordinary-looking reply — the sentence
    /// "This service allows sftp connections only." on *stdout*, exit 1, empty stderr — so from here
    /// it is indistinguishable from a shell that ran something. Only the core's
    /// `SSHFindListingParser` can tell, because only it knows what a good answer looks like, and it
    /// falls back to the walk when it does not see one.
    ///
    /// That is also why there is no memo of accounts that refused. It would have to be fed by the
    /// core rather than learned here, and it would save exactly **one** handshake in front of a walk
    /// that is about to spend one per directory — a saving too small to be worth a second place for
    /// this decision to live.
    ///
    /// Cancellation travels rather than degrading to `nil`: it is the caller's own instruction, not
    /// a property of the server.
    func runCommand(_ command: String, isCancelled: () -> Bool) throws -> String? {
        do {
            return try run(exec: command, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
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
    private func run(
        batch command: String,
        tolerateChannelHold: Bool = false,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = SFTPProcessArguments.batch(
            location: location,
            authentication: authentication,
            connectTimeout: connectTimeout
        )

        let captured = try capture(
            process,
            // Feed the single batch command, then EOF so sftp runs it and exits.
            stdin: Data((command + "\n").utf8),
            launchFailure: String(
                localized: "Couldn’t launch sftp.",
                comment: "SFTP failure: the sftp binary could not be spawned."
            ),
            watching: source,
            progress: progress,
            isCancelled: isCancelled
        )

        if captured.timedOut {
            if tolerateChannelHold {
                // The server replied but never closed the channel; the reply is complete, so hand it
                // back (only the single-line connect probe opts in — a multi-row listing must not be
                // read partially, hence the throw below).
                return captured.standardOutput
            }
            throw SFTPTransportError.failure(String(
                localized: "The SFTP server stopped responding.",
                comment: "SFTP failure: the server held the channel open past the timeout."
            ))
        }
        if captured.terminationStatus != 0 {
            throw SFTPTransportError.classify(stderr: captured.standardError)
        }
        // An interactive (password) session exits zero even on a failed command, so its errors live
        // only in stderr — scan for them; key auth's `-b -` already fails non-zero above.
        if isPasswordAuthentication, let error = SFTPTransportError.detect(
            stderr: captured.standardError
        ) {
            throw error
        }
        return captured.standardOutput
    }

    /// Run one `ssh` exec channel and return its stdout, whatever the server made of the command.
    ///
    /// **Nothing here classifies the result, and that is measured rather than lazy.** Probed
    /// 2026-08-16 against a real `sshd`: an `sftp`-only account answers exit 1 with prose on
    /// *stdout* and an empty stderr, while `find` answers exit **1 with correct rows** whenever one
    /// subdirectory was unreadable. So neither stream nor status separates "this worked" from "this
    /// account has no shell" — only the shape of the output does, which is
    /// `SSHFindListingParser`'s job in the core. What this owes the caller is the bytes and a throw
    /// when there are none to be had.
    private func run(exec command: String, isCancelled: () -> Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SFTPProcessArguments.exec(
            location: location,
            authentication: authentication,
            connectTimeout: connectTimeout,
            command: command
        )
        let captured = try capture(
            process,
            // Closed immediately: `find` reads nothing, and an open stdin would leave a server that
            // ignores the command waiting on a channel nobody is going to write to.
            stdin: Data(),
            launchFailure: String(
                localized: "Couldn’t launch ssh.",
                comment: "SFTP failure: the ssh binary could not be spawned."
            ),
            isCancelled: isCancelled
        )
        guard !captured.timedOut else {
            throw SFTPTransportError.failure(String(
                localized: "The SFTP server stopped responding.",
                comment: "SFTP failure: the server held the channel open past the timeout."
            ))
        }
        return captured.standardOutput
    }

    private var isPasswordAuthentication: Bool {
        if case .password = authentication { return true }
        return false
    }

    /// What a finished child left behind. `timedOut` is a *state*, not an error, because one caller
    /// (the connect probe) accepts the output anyway.
    private struct Captured {
        let standardOutput: String
        let standardError: String
        let terminationStatus: Int32
        let timedOut: Bool
    }

    /// Spawn `process`, write `stdin`, drain both pipes and wait — the plumbing `sftp` and `ssh`
    /// share, kept in one place so a fix to the deadlock or the cancellation reaches both. Blocks;
    /// call it off the main thread.
    private func capture(
        _ process: Process,
        stdin: Data,
        launchFailure: String,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool
    ) throws -> Captured {
        if isPasswordAuthentication {
            process.environment = try passwordEnvironment()
        }

        // Built **before** the child is spawned: a resumed `get -a` continues into a file that
        // already holds bytes, and the watch's baseline has to be read while it is still standing
        // still, or part of what is already on disk is counted as this transfer's.
        let watch = TransferProgressWatch(source)

        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        // Joined before `run()`, and waited on below beside the two drains — never
        // `waitUntilExit()`, which is a ≈71 ms poll paid once per invocation (`ProcessWaiting`).
        let group = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: group)

        do {
            try process.run()
        } catch {
            throw SFTPTransportError.failure(launchFailure)
        }

        input.fileHandleForWriting.write(stdin)
        try? input.fileHandleForWriting.close()

        // Drain both pipes on background queues — so neither can fill and deadlock the other on a
        // large listing — and join them through a group, which lets a password session bound its
        // wait (an unresponsive server must not hang the pane).
        var outputData = Data()
        var errorData = Data()
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

        // Only the interactive (password) session is time-bounded — see `passwordTimeout`. The
        // key-auth path waits as long as the transfer takes, which is why cancellation had to reach
        // in here rather than ride on a deadline: without it, Stop on a large `get` was noticed only
        // once the whole file had arrived (docs/NOTES.md ▸ curl for S3, measured on the sibling
        // transport).
        let deadline: DispatchTime = isPasswordAuthentication
            ? .now() + .seconds(passwordTimeout)
            : .distantFuture
        var timedOut = false
        switch ProcessWaiting.wait(
            for: group,
            deadline: deadline,
            isCancelled: isCancelled,
            onPoll: { watch.report(to: progress) }
        ) {
        case .finished:
            break
        case .cancelled:
            process.terminate()
            group.wait()
            throw CancellationError()
        case .timedOut:
            process.terminate() // SIGTERM closes the pipes so the drains unblock
            timedOut = true
        }
        group.wait() // terminate closed the pipes, so the readers finish promptly

        return Captured(
            standardOutput: String(bytes: outputData, encoding: .utf8) ?? "",
            standardError: String(bytes: errorData, encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus,
            timedOut: timedOut
        )
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
