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
    /// selection); a `perFile` script yields one per selected file. `inherited` is the environment
    /// the child starts from, and `systemPaths` the directory whose `paths` and `paths.d` widen its
    /// `PATH`: the app's own environment and `/etc`, or fixtures in a test.
    @MainActor
    static func run(
        _ script: UserScript,
        context: UserScriptContext,
        shell: String,
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        systemPaths: URL = ToolSearchPath.systemRoot,
        completion: @escaping (RunOutcome) -> Void
    ) {
        let invocations = script.invocations(in: context, shell: shell)
        Task {
            let failures = await BlockingWork.run { () -> [InvocationFailure] in
                // Every invocation of a run shares one folder, so one shell startup answers for
                // all of them: a `perFile` script over 400 photos asks once, not 400 times.
                guard let workingDirectory = invocations.first?.currentDirectoryPath else {
                    return []
                }
                let environment = baseEnvironment(
                    inherited: inherited,
                    shell: shell,
                    workingDirectory: workingDirectory,
                    systemPaths: systemPaths
                )
                return invocations.compactMap { runOne($0, inheriting: environment) }
            }
            completion(RunOutcome(script: script, total: invocations.count, failures: failures))
        }
    }

    /// Launch one invocation and wait for it, returning `nil` on success or a failure record on a
    /// non-zero exit / launch error. Runs on a background thread (the caller's detached task).
    private static func runOne(
        _ invocation: UserScriptInvocation,
        inheriting environment: [String: String]
    ) -> InvocationFailure? {
        let files = Array(invocation.arguments.dropFirst(argumentsBeforeFiles))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: invocation.currentDirectoryPath)
        process.environment = environment.merging(invocation.environment) { $1 }

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        let awaitExit = ProcessWaiting.exitWaiter(for: process)
        do {
            try process.run()
        } catch {
            return InvocationFailure(files: files, exitCode: nil, stderr: error.localizedDescription)
        }
        // Read stderr to end *before* waiting so the child can't block on a full pipe.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        awaitExit()
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

    /// The child's environment before the script's `DIRNEX_*` variables go on top: `inherited`,
    /// with the `PATH` the user's terminal has.
    ///
    /// A GUI process launched by LaunchServices inherits launchd's minimal `PATH`, so `cwebp`,
    /// `cargo`, `dotnet` and friends (the whole reason to write a script) would fail to resolve,
    /// and `python3` would be Apple's rather than the user's. So the user's shell is asked first
    /// (`LoginShellPathReader`). It starts in the script's own folder, so a startup file that looks
    /// at the current folder sees the script's. `ToolSearchPath` then appends the Homebrew
    /// prefixes and what `/etc/paths.d` names, which is all there is when the shell does not answer
    /// in time.
    private static func baseEnvironment(
        inherited: [String: String],
        shell: String,
        workingDirectory: String,
        systemPaths: URL
    ) -> [String: String] {
        let shellPath = LoginShellPathReader.directories(
            shell: shell,
            environment: inherited,
            workingDirectory: workingDirectory
        )
        var environment = inherited
        environment["PATH"] = ToolSearchPath.widening(
            shellPath?.joined(separator: ":") ?? inherited["PATH"],
            adding: ToolSearchPath.systemDirectories(
                in: systemPaths,
                home: inherited["HOME"] ?? NSHomeDirectory()
            )
        )
        return environment
    }
}
