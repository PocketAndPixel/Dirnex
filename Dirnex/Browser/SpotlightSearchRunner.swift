import DirnexCore
import Foundation

/// Runs a `FileQuery` by shelling out to `mdfind` off the main thread, then stats the
/// resulting paths into `FileEntry`s a virtual panel can render (PLAN.md §M4 "mdfind-backed …
/// streamed results"). The non-hermetic I/O — spawning the subprocess, statting files — lives
/// here in the app layer, mirroring `DirectoryLoader`; all the tested query logic stays in
/// `DirnexCore.FileQuery`.
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
        _ query: FileQuery,
        scope: VFSPath?,
        backend: any VFSBackend
    ) async -> Results {
        await results(forPaths: await paths(query, scope: scope), backend: backend)
    }

    /// Run Finder's **Recents** (PLAN.md §M8) — recently-used files everywhere — the same way a
    /// search runs, but from `RecentsQuery`'s own predicate rather than a user's `FileQuery`.
    /// The hits are all `.local`, so the caller's backend stats them exactly as it does search hits.
    ///
    /// Unlike a search, each hit comes back with the date it was last opened (PLAN.md §M40 Slice 2),
    /// so the cap keeps the newest rather than whichever paths `mdfind` printed first, and every row
    /// carries the date its Date column shows (`RecentsListing`).
    static func runRecents(
        _ query: RecentsQuery,
        backend: any VFSBackend
    ) async -> Results {
        let arguments = query.mdfindArguments()
        return await BlockingWork.run {
            let hits = RecentsQuery.hits(fromOutput: mdfindOutput(arguments: arguments) ?? Data())
            let listing = RecentsListing(hits: hits, limit: resultLimit) { path in
                try? backend.stat(at: .local(path))
            }
            return Results(entries: listing.entries, truncated: listing.truncated)
        }
    }

    /// Cap `paths` to the rendering budget and stat the survivors into entries, off the main thread —
    /// a search's tail; Recents caps by date instead (`runRecents`). Anything that vanished between
    /// the index and now is silently skipped.
    private static func results(
        forPaths paths: [String],
        backend: any VFSBackend
    ) async -> Results {
        let kept = paths.prefix(resultLimit)
        guard !kept.isEmpty else { return Results(entries: [], truncated: false) }

        return await BlockingWork.run {
            var entries: [FileEntry] = []
            entries.reserveCapacity(kept.count)
            for path in kept {
                if let entry = try? backend.stat(at: .local(path)) {
                    entries.append(entry)
                }
            }
            return Results(entries: entries, truncated: paths.count > kept.count)
        }
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
    static func paths(_ query: FileQuery, scope: VFSPath? = nil) async -> [String] {
        await paths(arguments: query.mdfindArguments(scopePath: scope?.path))
    }

    /// The paths `mdfind` reports for a ready-made argument vector. Empty for an empty vector or any
    /// `mdfind` failure.
    private static func paths(arguments: [String]) async -> [String] {
        guard !arguments.isEmpty else { return [] }
        return await BlockingWork.run {
            runMdfind(arguments: arguments)
        }
    }

    /// Spawn `mdfind` and collect its newline-delimited absolute paths. Returns an empty list on
    /// any failure (spawn error, non-UTF-8 output) — a failed search is an empty result, not a
    /// crash.
    private static func runMdfind(arguments: [String]) -> [String] {
        guard let data = mdfindOutput(arguments: arguments),
              let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Everything `mdfind` printed for `arguments`, or `nil` when it could not be started. stderr
    /// is discarded so a Spotlight warning never pollutes the output.
    private static func mdfindOutput(arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let awaitExit = ProcessWaiting.exitWaiter(for: process)
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read to EOF before waiting so a large result set can't deadlock on a full pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        awaitExit()
        return data
    }
}
