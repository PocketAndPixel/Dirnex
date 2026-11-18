import DirnexCore
import Foundation

/// Asks Spotlight whether it covers a folder on this Mac, so ⌥F7 knows whether to search the index
/// or walk the folder (PLAN.md §M40 Slice 3).
///
/// The sibling of `SpotlightSearchRunner`, with the same division: the arguments and the reading of
/// what comes back are the tested `DirnexCore.SpotlightCoverage`, and this owns the two processes and
/// the one syscall that tells a volume's root from any other folder.
enum SpotlightCoverageCheck {
    /// How long Spotlight may take to answer before the folder is walked instead. The question took
    /// 0.05–0.35 s on this Mac (2026-11-18); a `mds` that has stopped answering would otherwise hold
    /// the search for good, and a walk needs nothing from it.
    static let deadline: DispatchTimeInterval = .seconds(3)

    /// Whether Spotlight covers the folder at `path` on this Mac, asked off the main thread.
    static func covers(localFolder path: String) async -> Bool {
        await BlockingWork.run { covers(resolvedFolder: resolved(path)) }
    }

    /// The question itself, for a path with its symlinks already resolved: `mdfind` prints real
    /// paths, so `/tmp/x` would never match the `/private/tmp/x` it reports.
    private static func covers(resolvedFolder path: String) -> Bool {
        if isMountPoint(path) {
            guard let output = run("/usr/bin/mdutil", ["-s", path]) else { return false }
            return SpotlightCoverage.volumeIsIndexed(mdutilOutput: SubprocessText.lossyUTF8(output))
        }
        guard let arguments = SpotlightCoverage.mdfindArguments(forFolder: path),
              let output = run("/usr/bin/mdfind", arguments) else { return false }
        return SpotlightCoverage.output(output, namesFolder: path)
    }

    /// `path` with every symlink in it resolved, or as it is when that fails. `realpath(3)` rather than
    /// `URL.resolvingSymlinksInPath()`, which turns `/private/tmp` back into `/tmp`.
    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// Whether `path` is where a volume is mounted, which only `mdutil` can answer for.
    private static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountPoint = withUnsafeBytes(of: &info.f_mntonname) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
        }
        return mountPoint == path
    }

    /// Everything `tool` printed, or `nil` when it could not start or did not finish by `deadline`.
    /// stderr is discarded: `mdfind` writes its own chatter there.
    private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Joined before `run()`, never `waitUntilExit()`, which is a ≈71 ms poll (`ProcessWaiting`).
        let group = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: group)
        do {
            try process.run()
        } catch {
            return nil
        }
        let drained = Drained()
        group.enter()
        ProcessWaiting.pipeQueue("app.dirnex.spotlight-coverage").async {
            drained.output = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        switch ProcessWaiting.wait(for: group, deadline: .now() + deadline, isCancelled: { false }) {
        case .finished:
            return drained.output
        case .timedOut, .cancelled:
            process.terminate() // SIGTERM closes the pipe so the drain unblocks
            group.wait()
            return nil
        }
    }

    /// Written by the drain before it leaves the group and read only after the group is done.
    private final class Drained: @unchecked Sendable {
        var output = Data()
    }
}
