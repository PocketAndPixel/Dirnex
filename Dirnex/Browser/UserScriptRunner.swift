import DirnexCore
import Foundation

/// Runs a user script against the current selection — the app-side, non-hermetic half of the
/// automation item (PLAN.md §M6). The pure `DirnexCore.UserScript` decides *what* to launch (the
/// argv/env, and the security boundary that keeps attacker-controlled filenames out of the command
/// text); this only spawns the resolved invocations and reports how they went, mirroring
/// `ExternalDiffLauncher`'s pattern of running child processes off the main thread.
///
/// Invocations run **sequentially**: a `perFile` "convert 400 photos" script must not fork 400
/// `cwebp`s at once and thrash the disk (and the user's fans). New files land through the pane's
/// existing FSEvents watch, so there is no progress UI here — on success the runner stays silent
/// (like a Service), and only a non-zero exit or a launch failure raises a summary.
enum UserScriptRunner {
    /// The outcome of one `perFile`/`combined` invocation that did not succeed.
    struct InvocationFailure {
        /// The files that invocation targeted (one for `perFile`, the whole selection for
        /// `combined`) — for naming the offending item in the summary.
        let files: [String]
        /// The process exit status, or `nil` when the shell could not be launched at all.
        let exitCode: Int32?
        /// Whatever the script wrote to stderr, trimmed — the actionable part of the message.
        let stderr: String
    }

    /// The result of running every invocation of a script.
    struct RunOutcome {
        let script: UserScript
        /// How many invocations were launched (0 when a `perFile` script had nothing selected).
        let total: Int
        /// The ones that failed, in run order. Empty on full success.
        let failures: [InvocationFailure]
    }

    /// Run `script` against `context` using `shell`, off the main thread, then report the outcome
    /// back on the main actor. A `combined` script yields one invocation (even for an empty
    /// selection); a `perFile` script yields one per selected file.
    @MainActor
    static func run(
        _ script: UserScript,
        context: UserScriptContext,
        shell: String,
        completion: @escaping (RunOutcome) -> Void
    ) {
        let invocations = script.invocations(in: context, shell: shell)
        Task {
            let failures = await Task.detached(priority: .userInitiated) { () -> [InvocationFailure] in
                invocations.compactMap(runOne)
            }.value
            completion(RunOutcome(script: script, total: invocations.count, failures: failures))
        }
    }

    /// Launch one invocation and wait for it, returning `nil` on success or a failure record on a
    /// non-zero exit / launch error. Runs on a background thread (the caller's detached task).
    private static func runOne(_ invocation: UserScriptInvocation) -> InvocationFailure? {
        let files = Array(invocation.arguments.dropFirst(argumentsBeforeFiles))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: invocation.currentDirectoryPath)
        process.environment = childEnvironment(merging: invocation.environment)

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return InvocationFailure(files: files, exitCode: nil, stderr: error.localizedDescription)
        }
        // Read stderr to end *before* waiting so the child can't block on a full pipe.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let stderr = (String(bytes: errorData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return InvocationFailure(
            files: files,
            exitCode: process.terminationStatus,
            stderr: stderr
        )
    }

    /// The fixed prefix of `UserScript`'s argument vector before the file arguments begin:
    /// `["-c", <command>, <name>]` (see `UserScript.invocations`). The files are everything after.
    private static let argumentsBeforeFiles = 3

    /// The child's environment: the app's own, with a `PATH` widened to the tool directories a
    /// login shell would add, then the script's `DIRNEX_*` variables layered on top.
    ///
    /// A GUI process launched by LaunchServices inherits launchd's minimal `PATH`, without the
    /// Homebrew / user-tool locations a login shell picks up from `~/.zprofile` — so `cwebp`,
    /// `ffmpeg`, and friends (the whole reason to write a script) would fail to resolve. We union
    /// the standard tool directories onto the inherited `PATH` rather than paying for a full
    /// login-shell handshake per invocation; a directory that doesn't exist is inert in `PATH`, so
    /// including both the Apple-silicon and Intel Homebrew prefixes costs nothing.
    private static func childEnvironment(merging overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        var merged = existing
        for path in toolDirectories where !merged.contains(path) { merged.append(path) }
        environment["PATH"] = merged.joined(separator: ":")
        for (key, value) in overrides { environment[key] = value }
        return environment
    }

    private static let toolDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]
}
