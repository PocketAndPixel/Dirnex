import Foundation

/// SFTP's answer to ``VFSBackend/listDirectories(at:isCancelled:)``: several folders listed in
/// **one** `sftp` session, which is what a tree refresh re-lists every round.
///
/// FTP's version (`FTPBackend+Listings`) came first, for a cost measured on the case that reported
/// it, and this one closes the same gap here. `sftp` keeps no session between invocations, so each
/// folder's listing is a fresh TCP connect, key exchange and authentication — 71 ms on loopback, a
/// real handshake over a network — and the refresh poll spaces its rounds by what the last one
/// cost (``RemoteRefreshPolicy``). A tree with three folders open paid three handshakes a round; it
/// now pays one. ``SFTPBatchListing`` says how one session lists them all.
///
/// The fallback rules are FTP's, for FTP's reasons, and its file carries the argument in full.
public extension SFTPBackend {
    func listDirectories(at paths: [VFSPath], isCancelled: () -> Bool) throws -> [[FileEntry]?] {
        for path in paths {
            try requireOwnBackend(path)
        }
        // One folder gains nothing from a batch: it is one session either way, and the single
        // listing is the route every other caller uses. A tree with nothing expanded is this case,
        // and so is list mode.
        guard paths.count > 1 else { return try listEach(paths, isCancelled: isCancelled) }

        let answers: [String?]
        do {
            answers = try transport.listDirectories(paths.map(\.path), isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try listEach(paths, isCancelled: isCancelled)
        }
        // **Some** answers is a session that worked and could not list particular folders: one
        // deleted since it was expanded, or a permission gap. **None** is what a session that never
        // got in looks like, and a wrong count is a transport that told us nothing we can
        // attribute; both go back to one listing per folder.
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
    /// as anything else: a key it no longer accepts, a host that is down. Asking again for every
    /// folder would then be a failed login apiece, every round, which `sshd`'s `MaxAuthTries` and
    /// any brute-force guard in front of it count. So the first folder decides. If it lists, the
    /// batch was the problem and the rest are listed singly; if it does not, nothing more is asked
    /// this round and every folder keeps the rows it had.
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
