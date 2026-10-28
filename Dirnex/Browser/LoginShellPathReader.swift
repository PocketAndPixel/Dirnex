import DirnexCore
import Foundation

/// Runs the user's shell once to learn the `PATH` their terminal has: the app-side, non-hermetic
/// half of `DirnexCore.ShellPathProbe`, which owns the command, the environment and the parse.
///
/// Blocking, so it runs on the script runner's background thread, once per run rather than once per
/// file of a `perFile` script. Measured 2026-10-21 on Oleg's Mac: `bash -l -i -c` took 4.0 ms
/// median against 1.9 ms for the `bash -c` every script already pays.
enum LoginShellPathReader {
    /// How long a shell's startup files may take before the run goes on without them. Generous for
    /// a slow but working setup, and short enough that a startup file waiting on something that
    /// never comes delays a script by seconds rather than forever.
    static let timeout: DispatchTimeInterval = .seconds(5)

    /// The directories `shell` puts on `PATH` when started as a login, interactive shell in
    /// `workingDirectory` with `environment`, or `nil` when it cannot be launched, does not finish
    /// within `timeout`, or writes nothing usable. The caller falls back to `ToolSearchPath` alone.
    ///
    /// **A shell that runs out of time is killed with its whole process group, by `SIGKILL`.**
    /// `Process` starts the child as the leader of a group of its own (measured: its pgid is its
    /// pid, not Dirnex's), and `terminate()` sends that group `SIGTERM`. Measured 2026-10-21 against
    /// a startup file that sleeps for 30 s:
    ///
    /// | | plain `sleep 30` | after `trap '' TERM` |
    /// |---|---|---|
    /// | `terminate()` | shell gone, nothing left | shell still running 3 s later |
    /// | `kill(pid, SIGKILL)` | shell gone, `sleep` left behind | shell gone, `sleep` left behind |
    /// | `killpg(pid, SIGKILL)` | shell gone, nothing left | shell gone, nothing left |
    ///
    /// Even when `terminate()` works, it only cuts the startup file short, and the shell then runs
    /// the command with half a `PATH`. The answer is thrown away on a timeout either way.
    static func directories(
        shell: String,
        environment: [String: String],
        workingDirectory: String,
        timeout: DispatchTimeInterval = timeout
    ) -> [String]? {
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-shell-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ShellPathProbe.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.environment = ShellPathProbe.environment(
            inheriting: environment,
            shell: shell,
            outputFile: outputFile.path,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "0"
        )
        // Nothing for a startup file to wait on, and no pipe for a background job to hold open.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: exited)
        do {
            try process.run()
        } catch {
            return nil
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            killpg(process.processIdentifier, SIGKILL)
            // The shell itself as well, so the wait below cannot hang if it was ever not the
            // leader of its own group.
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
            return nil
        }
        guard let text = try? String(contentsOf: outputFile, encoding: .utf8) else { return nil }
        return ShellPathProbe.directories(
            fromOutput: text,
            home: environment["HOME"] ?? NSHomeDirectory()
        )
    }
}
