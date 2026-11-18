import Foundation

/// Runs shell bodies **as root** through the standard macOS authentication dialog, the in-app half of
/// the attributes escalation (PLAN.md §M14 Slice 5, §M40 Slice 4). `do shell script … with
/// administrator privileges` is the system's own authorization flow: it runs as root, stays inside the
/// app, needs no entitlement, and works under ad-hoc signing (the reasons it was chosen over an
/// `SMAppService` helper, which every local build would be unable to run).
///
/// **The bodies arrive on stdin, never in the script's source.** A JXA script reads them from a pipe
/// this process holds, NUL-separated, and hands each to `doShellScript`: data, not code, so there is no
/// script-string escaping on top of the ``ShellQuoting`` inside each body, and no file on disk that
/// another process could change between writing and running. The pipe is also what lifts the batch
/// off `ARG_MAX`: each body still passes `execve` on its way to `/bin/sh` (the core keeps each under
/// half of it, `EscalatedAttributeBatch.bodyLimit`), but any number of them go in one process, which
/// is what lets one password cover them all. Probed 2026-11-18 unprivileged: a body carrying `$(…)`
/// ran inert, a 1 040 000-byte body ran beside a second, and a body after a failing one still ran.
///
/// **A failed body does not stop the next**, the recursive run's own rule for a per-item error; the
/// first failure's stderr comes back once all have run. A cancelled password dialog stops at once.
/// What actually landed is never read off the answer: the caller reads the items back.
enum AdministratorShell {
    enum Failure: Error, Equatable {
        /// The user dismissed the authentication dialog (error -128). Not an error to surface as a
        /// failure — the user chose not to proceed.
        case cancelled
        /// A body ran and failed; carries the tools' own stderr.
        case failed(String)
    }

    /// Run `bodies` as root, in order, suspending until all have run. The blocking `Process` work is
    /// done off the main actor, behind a continuation, so the app's run loop is not frozen while the
    /// SecurityAgent dialog is up. Throws ``Failure`` on cancel or a failed body.
    ///
    /// **On a serial queue of its own, never a global one**, for the rule ``ProcessWaiting
    /// /pipeQueue(_:qos:)`` records: GCD starts a global queue's block only while fewer threads are
    /// busy than there are CPUs, and blocked cooperative threads count. M14 shipped it on
    /// `DispatchQueue.global`.
    ///
    /// `privileged: false` runs the same script without the administrator flag, which is how the
    /// tests drive the transport with no password.
    static func run(_ bodies: [String], privileged: Bool = true) async throws {
        let bodies = bodies.filter { !$0.isEmpty }
        guard !bodies.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ProcessWaiting.pipeQueue("app.dirnex.administrator-shell", qos: .userInitiated).async {
                do {
                    try runSynchronously(bodies, privileged: privileged)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The JXA script. Exit 2 is a cancelled dialog; exit 1 carries the first failure's message on
    /// stderr, with `do shell script`'s carriage returns put back to newlines.
    ///
    /// **A cancel is either of two numbers.** AppleScript reports a cancelled password dialog as
    /// -128, and JXA can hand over the Authorization Services code underneath it, -60006
    /// (`errAuthorizationCanceled`), with the same "User canceled." for a message. Found live
    /// (2026-11-18): checking -128 alone read a real Cancel as a failure, and the multi-selection
    /// Save then went on to change the user's own items.
    static let script = """
    ObjC.import('Foundation');
    ObjC.import('stdlib');
    function run(argv) {
      const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
      const text = $.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding).js;
      const app = Application.currentApplication();
      app.includeStandardAdditions = true;
      const privileged = argv[0] === 'privileged';
      const cancelled = [-128, -60006];
      let failure = null;
      for (const body of text.split('\\0')) {
        if (body.length === 0) continue;
        try {
          app.doShellScript(body, { administratorPrivileges: privileged });
        } catch (error) {
          if (cancelled.includes(error.errorNumber)) $.exit(2);
          if (failure === null) failure = String(error.message);
        }
      }
      if (failure !== null) {
        const message = $(failure.replace(/\\r/g, '\\n'));
        $.NSFileHandle.fileHandleWithStandardError
          .writeData(message.dataUsingEncoding($.NSUTF8StringEncoding));
        $.exit(1);
      }
    }
    """

    private static func runSynchronously(_ bodies: [String], privileged: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, privileged ? "privileged" : "plain"]
        let input = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        let awaitExit = ProcessWaiting.exitWaiter(for: process)
        do {
            try process.run()
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        // The script reads all of stdin before running anything, so the whole write lands first and
        // closing the pipe is what lets it start. A script that died before reading would otherwise
        // end this whole process with `SIGPIPE` (docs/NOTES.md ▸ sftp / ssh), and the throwing write
        // turns the `EPIPE` into an error rather than an exception; the exit status then says why.
        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? writer.write(contentsOf: Data(bodies.joined(separator: "\0").utf8))
        try? writer.close()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        awaitExit()

        switch process.terminationStatus {
        case 0:
            return
        case 2:
            throw Failure.cancelled
        default:
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A cancel the script did not see as -128 still reads as one in osascript's own words.
            if message.contains("(-128)") { throw Failure.cancelled }
            throw Failure.failed(message)
        }
    }
}
