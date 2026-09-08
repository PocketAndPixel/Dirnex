import DirnexCore
import Foundation

/// The process half of ``SFTPProcessTransport``: spawning `sftp` (and `ssh` for the exec channel),
/// feeding the batch command in, answering the password prompt out-of-band, draining both pipes
/// without deadlocking, and bounding the wait.
///
/// Split out when the transport reached SwiftLint's `type_body_length` on gaining the ⇧F4 create
/// verb — by concept rather than by shaving lines, which is the house rule. The verbs in the other
/// file say *what* is asked of the server; this says how a subprocess is run. It is the same seam
/// ``FTPCurlTransport`` already sits on, and `S3CurlRunner` for the S3 side.
extension SFTPProcessTransport {
    /// Run one `sftp` batch command and return its stdout. `sftp` prints the `sftp>` prompt echo and
    /// the `ls` rows to stdout (the parser ignores the echo) and errors to stderr, exiting non-zero
    /// on a failed command — so a non-zero status is classified from stderr. Blocks on `sftp`; call
    /// it off the main thread.
    /// Internal, not private: the verbs live in the other file and Swift's `private` is per-file
    /// (docs/NOTES.md ▸ Lint ceilings and file splitting).
    func run(
        batch command: String,
        tolerateChannelHold: Bool = false,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> String {
        try runCarrying(
            batch: command,
            tolerateChannelHold: tolerateChannelHold,
            watching: source,
            progress: progress,
            isCancelled: isCancelled
        ).output
    }

    /// The same run, also answering which **metadata steps** the server refused (PLAN.md §M25
    /// Slice 2).
    ///
    /// A metadata refusal must never be read as the transfer's failure, and `sftp` makes that easy
    /// to get wrong in two directions at once — measured 2026-08-28 against a real `sshd`:
    ///
    /// - `SFTPTransportError.detect(stderr:)` scans the whole stream for `permission denied` and
    ///   `no such file` before anything else, so a `chmod` refused after a `put` whose bytes had
    ///   already landed turned a perfectly good transfer into `.permissionDenied`. Hence the split
    ///   (``SFTPMetadataStderr``) ahead of every classification.
    /// - A batch **aborts on the first failed command and exits 1**, which is why the follow-up
    ///   lines are sent allowed-to-fail. The transfer's own `-p` cannot be: a failed `put` has to
    ///   stay a failed copy. So an exit code whose stderr is **nothing but** metadata refusals is
    ///   read as a transfer that worked and metadata that did not — the alternative is reporting a
    ///   file that is sitting there, correct, as a failure.
    ///
    /// Splitting unconditionally is safe because only a carrying batch can produce those lines at
    /// all: on every other run the remainder is byte-identical to what the classifier always saw.
    func runCarrying(
        batch command: String,
        tolerateChannelHold: Bool = false,
        watching source: TransferProgressWatch.Source = .none,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> (output: String, refusals: [RemoteMetadataRefusal]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = batchArguments

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
                // read partially, hence the throw below). Nothing that opts in carries metadata
                // steps, so there is nothing to report about them.
                return (captured.standardOutput, [])
            }
            throw SFTPTransportError.failure(String(
                localized: "The SFTP server stopped responding.",
                comment: "SFTP failure: the server held the channel open past the timeout."
            ))
        }
        let split = SFTPMetadataStderr.separate(stderr: captured.standardError)
        // `sftp` names the failing path and not the failing attribute, so which aspect went missing
        // is the backend's to work out from the plan it built; what reaches here is only that a step
        // was refused, in the remote's own words.
        let refusals = split.lines.map { RemoteMetadataRefusal.itemRefused($0) }

        if captured.terminationStatus != 0 {
            // An exit explained *entirely* by metadata refusals is not a failed transfer: the bytes
            // are on the server and the file is right.
            guard split.remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !refusals.isEmpty else {
                throw SFTPTransportError.classify(stderr: split.remainder)
            }
            return (captured.standardOutput, refusals)
        }
        // An interactive (password) session exits zero even on a failed command, so its errors live
        // only in stderr — scan for them; key auth's `-b -` already fails non-zero above.
        if isPasswordAuthentication, let error = SFTPTransportError.detect(
            stderr: split.remainder
        ) {
            throw error
        }
        return (captured.standardOutput, refusals)
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
    func run(exec command: String, isCancelled: () -> Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = execArguments(command: command)
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

    /// Internal for the reason ``childEnvironment()`` is.
    var isPasswordAuthentication: Bool {
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
        process.environment = try childEnvironment()

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

    /// The environment for every `sftp` and `ssh` child: the parent's (so `HOME`, `PATH` and the
    /// rest survive — `ssh` needs `HOME` to find `known_hosts`) with the locale pinned, plus, for
    /// password auth only, the `SSH_ASKPASS` wiring that feeds the password without a TTY.
    /// `SSH_ASKPASS_REQUIRE=force` makes modern OpenSSH use the helper even with no controlling
    /// terminal.
    ///
    /// **Every child is armed, not just the password ones**, which is what fixes a listing rather
    /// than half of them: key auth used to leave `environment` nil and inherit the app's own, and a
    /// LaunchServices-launched app has no locale at all — so `sftp` ran under `C` and octal-escaped
    /// every non-ASCII byte of every name (``ChildProcessLocale``). The two paths differed in
    /// exactly the way that hid it.
    ///
    /// Internal rather than private so the segmented download and upload can arm each of their
    /// children with it — Swift's `private` does not cross files (docs/NOTES.md ▸ file splitting).
    func childEnvironment() throws -> [String: String] {
        var environment = ChildProcessLocale.inherited()
        guard isPasswordAuthentication else { return environment }
        environment["SSH_ASKPASS"] = try SFTPAskpassHelper.scriptPath()
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment[SFTPAskpassHelper.passwordEnvironmentKey] = password ?? ""
        return environment
    }
}
