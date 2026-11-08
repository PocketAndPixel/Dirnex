import Darwin
import DirnexCore
import Foundation

/// `Dirnex --git-merge "$LOCAL" "$BASE" "$REMOTE" "$MERGED"`: the app's own binary as a plain
/// command, which is how `git mergetool` reaches Dirnex (PLAN.md §M37 Slice 6).
///
/// It runs first in `main.swift`, before anything builds a window, so it never shows in the Dock. It
/// asks the copy of the app it belongs to for a merge window over a private socket, launching that
/// copy if it is not up, waits for the window to close, and exits 0 if a result was saved and 1 for
/// anything else. git decides what that means: under `trustExitCode`, 0 stages the file.
enum GitMergeCommand {
    /// Run the command if `arguments` ask for it, and answer the status to exit with. `nil` for a
    /// normal launch.
    static func runIfAsked(_ arguments: [String]) -> Int32? {
        guard GitMergeArguments.isInvocation(arguments) else { return nil }
        let finished = run(
            arguments,
            currentDirectory: FileManager.default.currentDirectoryPath,
            socket: GitMergeSocketLocation.path,
            bundlePath: GitMergeSocketLocation.bundlePath
        )
        if let message = finished.message {
            FileHandle.standardError.write(Data("dirnex: \(message)\n".utf8))
        }
        return finished.exitCode
    }

    /// The command's work. Blocks for as long as the merge window is open.
    static func run(
        _ arguments: [String],
        currentDirectory: String,
        socket: String?,
        bundlePath: String
    ) -> GitMergeClient.Finished {
        guard let request = GitMergeArguments.request(
            from: arguments,
            currentDirectory: currentDirectory
        ) else {
            return GitMergeClient.Finished(exitCode: 1, message: GitMergeArguments.usage)
        }
        guard let socket else {
            return GitMergeClient.Finished(
                exitCode: 1,
                message: "this account's home folder has too long a path for Dirnex's socket."
            )
        }
        return GitMergeClient.run(
            request,
            transport: GitMergeCommandTransport(socket: socket, bundlePath: bundlePath)
        )
    }
}

/// Where this copy of Dirnex listens, which the command and the app work out the same way.
enum GitMergeSocketLocation {
    /// The app this binary belongs to, however it was reached.
    static var bundlePath: String {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path
    }

    static var supportDirectory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("Dirnex", isDirectory: true)
    }

    /// `nil` when the path would be too long for a socket.
    static var path: String? {
        supportDirectory.flatMap {
            GitMergeSocketPath.path(supportDirectory: $0.path, bundlePath: bundlePath)
        }
    }
}

/// The command's transport: the real socket, and `/usr/bin/open` for the launch, so a launched app
/// is its own process with its own Full Disk Access rather than a child of the terminal.
struct GitMergeCommandTransport: GitMergeClientTransport {
    let socket: String
    let bundlePath: String

    func connect() -> GitMergeConnectResult<GitMergeSocketConnection> {
        GitMergeSocket.connect(to: socket)
    }

    /// `open` with the path starts this copy even with another copy of the same bundle id running,
    /// and only brings it to the front when it is already up (both measured 2026-11-09).
    func openApp() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [bundlePath]
        process.environment = GitMergeClient.launchEnvironment(
            from: ProcessInfo.processInfo.environment
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func sleep(seconds: Double) {
        usleep(useconds_t(seconds * 1_000_000))
    }

    func uptime() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}
