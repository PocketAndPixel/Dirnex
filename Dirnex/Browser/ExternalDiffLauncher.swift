import DirnexCore
import Foundation

/// Launches an external visual diff tool on two on-disk files — the app-side, non-hermetic half of
/// Compare-by-content (PLAN.md §M5). `ByteComparator` says *whether* two files differ; this opens
/// them side-by-side in FileMerge, Kaleidoscope, or BBEdit so the user can see *how*.
///
/// The which-tool / how-to-invoke logic is the pure, tested `DirnexCore.ExternalDiffTool`; this
/// only supplies the filesystem probe (does the launcher exist?) and spawns the resolved command,
/// mirroring `ArchiveExtractor`'s pattern of running a child process off the main thread.
enum ExternalDiffLauncher {
    /// Why a compare-contents request couldn't be fulfilled.
    enum Failure: Error {
        /// No known diff tool (FileMerge, Kaleidoscope, BBEdit) is installed.
        case noToolInstalled
        /// The tool's launcher was found but couldn't be spawned.
        case launchFailed(tool: ExternalDiffTool)
    }

    /// The probe injected into the pure model: whether `path` is an existing, executable file.
    static func executableExists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// The tool a Compare-with action would use, or `nil` when none is installed — the user's
    /// Settings choice when that tool is still installed, else the automatic install order. Cheap
    /// (a few file-existence checks), so callers use it to title and enable the menu item.
    @MainActor
    static func preferredTool() -> ExternalDiffTool? {
        let chosen = AppPreferences.shared.diffToolIdentifier
        return ExternalDiffTool.preferred(
            identifier: chosen.isEmpty ? nil : chosen,
            where: executableExists
        )
    }

    /// Every known tool actually installed, in the automatic preference order — the list the
    /// Settings picker offers. Empty when the user has none of them.
    static func installedTools() -> [ExternalDiffTool] {
        ExternalDiffTool.installed(where: executableExists)
    }

    /// Spawn the preferred installed diff tool on the two local files, off the main thread.
    /// `completion` reports the outcome back on the main actor; on success it carries the tool that
    /// was launched (for a status message). The child process is launched and left to run on its
    /// own — we never block on the GUI tool's lifetime.
    @MainActor
    static func compare(
        _ leftPath: String,
        _ rightPath: String,
        completion: @escaping (Result<ExternalDiffTool, Failure>) -> Void
    ) {
        guard let tool = preferredTool(),
              let invocation = tool.invocation(
                  comparing: leftPath,
                  with: rightPath,
                  executableExists: executableExists
              ) else {
            completion(.failure(.noToolInstalled))
            return
        }
        Task {
            let launched = await Task.detached(priority: .userInitiated) { () -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: invocation.executablePath)
                process.arguments = invocation.arguments
                // Nothing consumes the tool's streams; discard both so a chatty launcher can't
                // stall on a full pipe or spam the console.
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run() // launch and detach — the GUI tool outlives this task
                    return true
                } catch {
                    return false
                }
            }.value
            completion(launched ? .success(tool) : .failure(.launchFailed(tool: tool)))
        }
    }
}
