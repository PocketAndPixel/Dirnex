import DirnexCore
import Foundation

/// Runs a `SpotlightQuery` by shelling out to `mdfind` off the main thread, then stats the
/// resulting paths into `FileEntry`s a virtual panel can render (PLAN.md §M4 "mdfind-backed …
/// streamed results"). The non-hermetic I/O — spawning the subprocess, statting files — lives
/// here in the app layer, mirroring `DirectoryLoader`; all the tested query logic stays in
/// `DirnexCore.SpotlightQuery`.
enum SpotlightSearchRunner {
    /// The most results materialized into a panel. A broad query ("every image on disk") can
    /// return hundreds of thousands of paths; statting and rendering all of them would wedge the
    /// UI for no benefit, so the panel shows the first `resultLimit` and flags the truncation.
    static let resultLimit = 5000

    /// The outcome of a search: the entries to list, plus whether more matched than were kept.
    struct Results: Sendable {
        let entries: [FileEntry]
        let truncated: Bool
    }

    /// Search for `query` within `scope` (its subtree), or everywhere indexed when `scope` is
    /// `nil`. Stats each hit with `backend` — anything that vanished between the index and now is
    /// silently skipped. Runs entirely off the main thread.
    static func run(
        _ query: SpotlightQuery,
        scope: VFSPath?,
        backend: any VFSBackend
    ) async -> Results {
        let paths = await paths(query, scope: scope)
        let kept = paths.prefix(resultLimit)
        guard !kept.isEmpty else { return Results(entries: [], truncated: false) }

        return await Task.detached(priority: .userInitiated) {
            var entries: [FileEntry] = []
            entries.reserveCapacity(kept.count)
            for path in kept {
                if let entry = try? backend.stat(at: .local(path)) {
                    entries.append(entry)
                }
            }
            return Results(entries: entries, truncated: paths.count > kept.count)
        }.value
    }

    /// The paths matching `query`, as `mdfind` reports them — unstatted and **uncapped**.
    ///
    /// The cap `run` applies is a rendering budget, and it belongs to rendering: a caller that means
    /// to *act* on every match — stripping a tag from the files carrying it — has to see all of
    /// them, because a half-applied edit here would leave the tag alive on the files past the limit
    /// and the deletion silently incomplete. Statting is likewise `run`'s business; this answers the
    /// question "which paths?" and nothing more.
    ///
    /// Empty for an empty query, and empty on any `mdfind` failure — callers cannot distinguish
    /// "no matches" from "the search didn't run", so this must not be the last word before something
    /// destructive. It isn't: nothing is deleted from a file that doesn't come back as a match.
    static func paths(_ query: SpotlightQuery, scope: VFSPath? = nil) async -> [String] {
        let arguments = query.mdfindArguments(scopePath: scope?.path)
        guard !arguments.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            runMdfind(arguments: arguments)
        }.value
    }

    /// Spawn `mdfind` and collect its newline-delimited absolute paths. Returns an empty list on
    /// any failure (spawn error, non-UTF-8 output) — a failed search is an empty result, not a
    /// crash. stderr is discarded so a Spotlight warning never pollutes the paths.
    private static func runMdfind(arguments: [String]) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        // Read to EOF before waiting so a large result set can't deadlock on a full pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
