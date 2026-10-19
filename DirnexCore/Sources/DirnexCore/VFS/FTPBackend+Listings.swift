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
    func listDirectories(at paths: [VFSPath], isCancelled: () -> Bool) throws -> [[FileEntry]?] {
        for path in paths {
            try requireOwnBackend(path)
        }
        // One folder gains nothing from a batch, and the single `LIST` is the route that carries the
        // TLS-1.2 retry for a data channel that returned nothing (`FTPCurlTransport+Batch` explains
        // why the batch has none). A tree with nothing expanded is this case, and so is list mode.
        guard paths.count > 1 else { return try listEach(paths, isCancelled: isCancelled) }

        let answers: [String?]
        do {
            answers = try transport.listDirectories(paths.map(\.path), isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try listEach(paths, isCancelled: isCancelled)
        }
        // **Some** answers is a working session that refused particular folders — a permission gap,
        // or one deleted since it was expanded — and that refusal is the server's answer about those
        // folders. **None** is the shape of the batch itself failing (`FTPCurlTransport+Batch`: a
        // run in which nothing landed), and a wrong count is a transport that has told us nothing
        // we can attribute; both go back to one listing per folder.
        guard answers.count == paths.count, answers.contains(where: { $0 != nil }) else {
            return try listEach(paths, isCancelled: isCancelled)
        }
        return zip(paths, answers).map { path, raw in
            raw.map { entries(fromListing: $0, in: path) }
        }
    }

    /// One listing per folder, giving up on the rest the moment the **first** one fails.
    ///
    /// Reached when the batch came back empty, which is a server that would not let us in as often
    /// as it is a batch the server did not like — a wrong password, an expired account, a host that
    /// is down. Trying every folder again would then be a failed login apiece, every round, and a
    /// server with brute-force protection counts those: Synology DSM's Account Protection locks an
    /// account after a handful (docs/NOTES.md ▸ Resolving a host name). So the first folder
    /// decides. If it lists, the batch was the problem and the rest are listed singly; if it does
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
