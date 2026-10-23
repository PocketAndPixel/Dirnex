import Foundation

/// FTP's answer to ``VFSBackend/listDirectories(at:isCancelled:)``: several folders listed over
/// **one** login, which is what a tree refresh re-lists every time it runs.
///
/// The cost it removes was measured on the case that reported it. On 2026-10-19 a tree with two
/// folders open on an FTPES server 41 ms away re-listed as three separate `curl` runs of 0.99 s,
/// 0.91 s and 0.99 s — each one a TCP connect, a TLS handshake on the control channel, a login and
/// a second handshake on the data channel, for a `LIST` that is a few hundred bytes. The refresh
/// poll spaces its rounds by what the last one cost (``RemoteRefreshPolicy``), so those three logins
/// stretched the 15 s floor to 59 s, and a file somebody had just written stayed out of the pane for
/// up to a minute. The batch keeps the listings and drops all but one of the logins.
public extension FTPBackend {
    /// The folders a tree refresh re-lists, over one login, in a run that **stops at its first
    /// failure** (``FTPTransport/listingsUntilFirstFailure(of:askingFacts:isCancelled:)``).
    ///
    /// A run that did not stop cost a failed login per folder when the password was wrong (measured
    /// 2026-10-23: four sections, four `failed login` lines, and then one more from ``listEach(_:isCancelled:)``).
    /// A refresh runs on a timer, so every round spent that again. Stopping is what bounds it, and
    /// what the stop was decides what comes next (``FTPBatchStop/Cause``):
    ///
    /// - **A folder's own refusal** — deleted since it was opened, or not readable — is that folder's
    ///   answer from a session that worked, so the folders after it go out in another run.
    /// - **A refused login** ends the round. Every folder keeps its last good rows, and the server
    ///   has been asked once.
    /// - **No answer** is the batch's failure as much as the server's, so the rest go one at a time,
    ///   as they did before this stopped (``listEach(_:isCancelled:)``): the single listing carries the
    ///   TLS-1.2 retry for a data channel that returned nothing, and its first folder decides.
    func listDirectories(at paths: [VFSPath], isCancelled: () -> Bool) throws -> [[FileEntry]?] {
        for path in paths {
            try requireOwnBackend(path)
        }
        // One folder gains nothing from a batch, and the single `LIST` is the route that carries the
        // TLS-1.2 retry for a data channel that returned nothing (`FTPCurlTransport+Batch` explains
        // why the batch has none). A tree with nothing expanded is this case, and so is list mode.
        guard paths.count > 1 else { return try listEach(paths, isCancelled: isCancelled) }

        var answers: [[FileEntry]?] = []
        var rest = paths[...]
        while !rest.isEmpty {
            guard !isCancelled() else { throw CancellationError() }
            let run: FTPBatchRun
            do {
                run = try transport.listingsUntilFirstFailure(
                    of: rest.map(\.path),
                    askingFacts: facts.asksWithBatch,
                    isCancelled: isCancelled
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try answers + listEach(Array(rest), isCancelled: isCancelled)
            }
            // One answer per request, in order, is the whole contract; any other number is a
            // transport that has told us nothing we can attribute.
            guard run.listings.count == rest.count else {
                return try answers + listEach(Array(rest), isCancelled: isCancelled)
            }
            let listed = zip(rest, run.listings).map { path, listing in
                listing.map { parsedRows(of: $0).map { entry(from: $0, in: path) } }
            }
            guard let stop = run.stop, listed.indices.contains(stop.index) else {
                return answers + listed
            }
            // Every folder up to the stop was answered, the stopping one too when it stopped on its
            // `MLSD` after its rows had landed.
            answers += listed.prefix(through: stop.index)
            let unsent = rest.dropFirst(stop.index + 1)
            switch stop.cause {
            case .folder:
                rest = unsent
            case .login:
                return answers + Array(repeating: nil, count: unsent.count)
            case .connection:
                answers.removeLast()
                return try answers + listEach(
                    Array(rest.dropFirst(stop.index)),
                    isCancelled: isCancelled
                )
            }
        }
        return answers
    }

    /// One listing per folder, giving up on the rest the moment the **first** one fails.
    ///
    /// Reached when the run got no answer or could not be read — a host that is down, or a data
    /// channel that needs the TLS-1.2 retry only the single listing carries. A refused **login** does
    /// not come here: the run says so (``FTPBatchStop/Cause/login``), and asking each folder again
    /// would be a failed login apiece, every round, which a server with brute-force protection
    /// counts: Synology DSM's Account Protection locks an account after a handful (docs/NOTES.md ▸
    /// Resolving a host name). The first folder decides all the same, for a login this reaches some
    /// other way. If it lists, the batch was the problem and the rest are listed singly; if it does
    /// not, nothing more is asked this round and every folder keeps the rows it had.
    private func listEach(_ paths: [VFSPath], isCancelled: () -> Bool) throws -> [[FileEntry]?] {
        var answers: [[FileEntry]?] = []
        for path in paths {
            guard !isCancelled() else { throw CancellationError() }
            guard let listed = try? listDirectory(at: path) else {
                if answers.isEmpty { return Array(repeating: nil, count: paths.count) }
                answers.append(nil)
                continue
            }
            answers.append(listed)
        }
        return answers
    }
}
