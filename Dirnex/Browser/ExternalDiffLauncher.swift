import AppKit
import DirnexCore

/// Launches an external visual diff tool on two on-disk files — the app-side, non-hermetic half of
/// Compare-by-content (PLAN.md §M5). `ByteComparator` says *whether* two files differ; this opens
/// them side-by-side in FileMerge, Kaleidoscope, or BBEdit so the user can see *how*.
///
/// The which-tool / how-to-invoke logic is the pure, tested `DirnexCore.ExternalDiffTool` and
/// `CompareTool`; this only supplies the probes (does the launcher exist, where is FileMerge) and
/// spawns the resolved command, mirroring `ArchiveExtractor`'s pattern of running a child process
/// off the main thread. Dirnex's own window is one of the answers since PLAN.md §M31 Slice 4, and
/// the pane opens that one itself.
@MainActor
enum ExternalDiffLauncher {
    /// Why a compare-contents request couldn't be fulfilled.
    enum Failure: Error {
        /// The tool's launcher was found but couldn't be spawned, or is gone since it was found.
        case launchFailed(tool: ExternalDiffTool)
    }

    /// The probe injected into the pure model: whether `path` is an existing, executable file.
    nonisolated static func executableExists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// Where LaunchServices has an application, by bundle identifier: how FileMerge, and so the
    /// Xcode that holds its `opendiff`, is found.
    static func bundlePath(forIdentifier identifier: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.path
    }

    /// What a Compare-with action would open: the user's Settings choice while it is installed,
    /// else Dirnex. Cheap (a few file-existence checks and one LaunchServices lookup), so callers
    /// use it to title the menu item.
    static func preferredTool() -> CompareTool {
        CompareTool.preferred(
            identifier: AppPreferences.shared.diffToolIdentifier,
            installed: installedTools()
        )
    }

    /// Every known tool actually installed, in `ExternalDiffTool.known`'s order — the list the
    /// Settings picker offers after Dirnex. Empty when the user has none of them.
    static func installedTools() -> [ExternalDiffTool] {
        ExternalDiffTool.installed(locateBundle: bundlePath(forIdentifier:), where: executableExists)
    }

    /// Spawn `tool` on the two local files, off the main thread. `completion` reports the outcome
    /// back on the main actor. The child process is launched and left to run on its own — we never
    /// block on the GUI tool's lifetime.
    static func compare(
        with tool: ExternalDiffTool,
        _ leftPath: String,
        _ rightPath: String,
        completion: @escaping (Result<ExternalDiffTool, Failure>) -> Void
    ) {
        guard let invocation = tool.invocation(
            comparing: leftPath,
            with: rightPath,
            executableExists: executableExists
        ) else {
            completion(.failure(.launchFailed(tool: tool)))
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
