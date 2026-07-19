import DirnexCore
import Foundation

/// Opens the user's own terminal at a directory — the "open in iTerm/Terminal/WezTerm as
/// alternative" half of PLAN.md §M6's terminal item, for people who want their tabs, their
/// profile, and their window rather than the ⌃` drawer.
///
/// `ExternalDiffLauncher`'s shape verbatim, over the pure `DirnexCore.ExternalTerminal`: the model
/// decides which terminal and how to invoke it, and this only supplies the filesystem probe and
/// spawns the result. The directory travels as an *argument vector*, never as shell text, so
/// nothing here quotes anything — the drawer's `ShellCommandLine` exists precisely because typing
/// at a shell is the case where that isn't true.
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
            let launched = await Task.detached(priority: .userInitiated) { () -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: invocation.executablePath)
                process.arguments = invocation.arguments
                // Nothing reads the launcher's streams; discard both so a chatty one can't stall
                // on a full pipe or spam the console.
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run() // launch and detach — the terminal outlives this task
                    return true
                } catch {
                    return false
                }
            }.value
            completion(launched ? .success(terminal) : .failure(.launchFailed(terminal: terminal)))
        }
    }
}
