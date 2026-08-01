import Foundation

/// Runs a shell command **as root** through the standard macOS authentication dialog — the in-app half
/// of Slice 5's escalation (PLAN.md §M14, option 2). `osascript`'s `do shell script … with
/// administrator privileges` is the system's own authorization flow: it runs as root, stays inside the
/// app, needs no entitlement, and works under ad-hoc signing (the reasons it was chosen over an
/// `SMAppService` helper, which every local build would be unable to run).
///
/// **The shell body is passed as an *argument*, never embedded in the AppleScript source.** With
/// `on run argv` / `do shell script (item 1 of argv)`, the body reaches AppleScript as a string
/// argument — data, not code — so there is no AppleScript-string escaping layer to get wrong on top of
/// the ``ShellQuoting`` already inside the body. Probed: a body containing quotes, backslashes and a
/// `$(…)` came back through `argv` untouched, with no substitution. The body itself is built and
/// quoted in the core (`EscalatedAttributeCommand`); this type only transports it.
enum AdministratorShell {
    enum Failure: Error {
        /// The user dismissed the authentication dialog (AppleScript error -128). Not an error to
        /// surface as a failure — the user chose not to proceed.
        case cancelled
        /// The elevated command ran and failed; carries the shell's own message (its exit was
        /// surfaced by `do shell script` as `execution error: <stderr> (<code>)`).
        case failed(String)
    }

    /// Run `scriptBody` as root, suspending until it finishes. The blocking `Process` work is done off
    /// the main actor (a global queue behind a continuation) so the app's run loop is not frozen while
    /// the SecurityAgent dialog is up — the dialog is a separate process, but `waitUntilExit` would
    /// otherwise beach-ball our UI behind it. Throws ``Failure`` on cancel or a failed run.
    static func run(_ scriptBody: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try runSynchronously(scriptBody)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSynchronously(_ scriptBody: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            "--", scriptBody
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }

        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Cancelling the auth dialog is AppleScript error -128 ("User canceled") — a choice, not a
        // failure, so it closes nothing and shows no error.
        if message.contains("-128") { throw Failure.cancelled }
        throw Failure.failed(message)
    }
}
