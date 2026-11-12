import DirnexCore
import Foundation

/// Opens the user's own terminal at a directory — the "open in iTerm/Terminal/WezTerm as
/// alternative" half of PLAN.md §M6's terminal item, for people who want their tabs, their
/// profile, and their window rather than the ⌃` drawer.
///
/// `ExternalDiffLauncher`'s shape verbatim, over the pure `DirnexCore.ExternalTerminal`: the model
/// decides which terminal and how to invoke it, and this only supplies the filesystem probe and
/// spawns the result. A local directory travels as an *argument vector*, never as shell text, so
/// nothing here quotes anything — the drawer's `ShellCommandLine` exists precisely because typing
/// at a shell is the case where that isn't true. An `ssh` session does go through a shell, and
/// `SSHTerminalSession` in the core is what quotes it.
enum ExternalTerminalLauncher {
    /// Why an open-in-terminal request couldn't be fulfilled.
    enum Failure: Error {
        /// The terminal's launcher was found but couldn't be spawned.
        case launchFailed(terminal: ExternalTerminal)
    }

    /// The probe injected into the pure model. An app bundle is a *directory*, not an executable
    /// file, so this asks the broader question `ExternalDiffLauncher` doesn't have to.
    static func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The terminal an open-in-terminal action would use. Never `nil` in practice — Terminal.app
    /// ships with macOS, which is what makes it the always-installed fallback — but the model is
    /// honest about a Mac that somehow has none, so this is too.
    static func preferredTerminal() -> ExternalTerminal? {
        ExternalTerminal.preferred(where: pathExists)
    }

    /// Open `directoryPath` in the preferred installed terminal, off the main thread. The child is
    /// launched and left to run on its own: the user's terminal outlives this task, and Dirnex has
    /// no business waiting on it.
    @MainActor
    static func open(
        directoryPath: String,
        completion: @escaping (Result<ExternalTerminal, Failure>) -> Void
    ) {
        guard let terminal = preferredTerminal(),
              let invocation = terminal.invocation(
                  openingDirectory: directoryPath,
                  pathExists: pathExists
              ) else { return }
        Task {
            let launched = await BlockingWork.run { spawn(invocation) }
            completion(launched ? .success(terminal) : .failure(.launchFailed(terminal: terminal)))
        }
    }

    /// Open an `ssh` session in the preferred installed terminal, off the main thread.
    ///
    /// The launch returns as soon as the terminal has been told, and the stage is left to wait for
    /// it on its own thread, for as long as a person might take to answer iTerm's "OK to run?".
    @MainActor
    static func open(
        session: SSHTerminalSession,
        secret: String?,
        completion: @escaping (Result<ExternalTerminal, Failure>) -> Void
    ) {
        guard let terminal = preferredTerminal() else { return }
        let closePrompt = String(
            localized: "Press Return to close.",
            comment: "Printed in the user's terminal after ssh could not connect or sign in."
        )
        Task {
            let launched = await BlockingWork.run {
                launch(session, secret: secret, closePrompt: closePrompt, in: terminal)
            }
            completion(launched ? .success(terminal) : .failure(.launchFailed(terminal: terminal)))
        }
    }

    private static func launch(
        _ session: SSHTerminalSession,
        secret: String?,
        closePrompt: String,
        in terminal: ExternalTerminal
    ) -> Bool {
        guard let stage = try? SSHTerminalStage(
            session: session,
            secret: secret,
            closePrompt: closePrompt
        ) else { return false }
        guard let invocation = terminal.invocation(
            runningScript: stage.scriptPath,
            pathExists: pathExists
        ), spawn(invocation) else {
            stage.discard()
            return false
        }
        DispatchQueue.global(qos: .utility).async { stage.finish() }
        return true
    }

    /// Launch and detach: the terminal outlives this task.
    private static func spawn(_ invocation: ExternalTerminalInvocation) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        // Nothing reads the launcher's streams; discard both so a chatty one can't stall on a full
        // pipe or spam the console.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
